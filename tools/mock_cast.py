#!/usr/bin/env python3
"""
Mock Google Cast receiver for testing Mira's Cast Streaming sender without hardware.

It behaves like a Chromecast running the built-in mirroring receiver (modelled on
openscreen's cast/streaming receiver):
  1. TLS on port 8009 (self-signed certificate), Cast v2 framed protobuf messages
  2. LAUNCH of app 0F5096E8 -> RECEIVER_STATUS with sessionId/transportId
  3. OFFER -> ANSWER with our UDP port and SSRCs
  4. receives Cast RTP: reassembles frames, decrypts (AES-128-CTR), checks frame IDs,
     sends RTCP receiver reports + Cast feedback (ACK checkpoint, NACKs), drops packet
     0 of frames that arrive before the first sender report (as real receivers do)
  5. writes the video elementary stream to a file for an ffmpeg decode check

Exit status 0 only if the session completed and the media was valid.

  python3 tools/mock_cast.py --duration 8 --out /tmp/cast.h264
  .build/debug/Mira connect 127.0.0.1 --cast --test-pattern
"""
import argparse
import asyncio
import json
import os
import random
import ssl
import struct
import subprocess
import sys
import tempfile
import time

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.x509.oid import NameOID
import datetime

NS_CONNECTION = "urn:x-cast:com.google.cast.tp.connection"
NS_HEARTBEAT = "urn:x-cast:com.google.cast.tp.heartbeat"
NS_RECEIVER = "urn:x-cast:com.google.cast.receiver"
NS_WEBRTC = "urn:x-cast:com.google.cast.webrtc"
MIRRORING_APP = "0F5096E8"
TRANSPORT_ID = "web-5"
NTP_EPOCH = 2208988800


def log(tag, msg):
    print(f"{time.strftime('%H:%M:%S')} [{tag}] {msg}", flush=True)


# ------------------------------------------------------------- protobuf ----

def varint(v):
    out = bytearray()
    while v >= 0x80:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)
    return bytes(out)


def encode_message(source, dest, namespace, payload):
    def field_bytes(n, b):
        return varint(n << 3 | 2) + varint(len(b)) + b
    body = varint(1 << 3) + varint(0)
    body += field_bytes(2, source.encode()) + field_bytes(3, dest.encode()) + field_bytes(4, namespace.encode())
    body += varint(5 << 3) + varint(0) + field_bytes(6, json.dumps(payload).encode())
    return struct.pack(">I", len(body)) + body


def decode_message(b):
    i, out = 0, {}
    def rd_varint():
        nonlocal i
        v, shift = 0, 0
        while True:
            c = b[i]; i += 1
            v |= (c & 0x7F) << shift
            if not c & 0x80:
                return v
            shift += 7
    while i < len(b):
        key = rd_varint()
        field, wire = key >> 3, key & 7
        if wire == 0:
            out[field] = rd_varint()
        elif wire == 2:
            n = rd_varint()
            out[field] = b[i:i + n]; i += n
        else:
            raise ValueError("unexpected wire type")
    assert out.get(1) == 0, "protocol_version must be CASTV2_1_0"
    return {
        "source": out[2].decode(), "dest": out[3].decode(), "ns": out[4].decode(),
        "payload": json.loads(out[6].decode()) if 6 in out else None,
    }


def make_cert():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Mock Chromecast")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=2)).sign(key, hashes.SHA256()))
    d = tempfile.mkdtemp()
    cp, kp = os.path.join(d, "cert.pem"), os.path.join(d, "key.pem")
    with open(cp, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))
    with open(kp, "wb") as f:
        f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL,
                                  serialization.NoEncryption()))
    return cp, kp


# ----------------------------------------------------------- media side ----

def expand(low8, ref):
    """8-bit frame id -> the id closest to ref with those low bits."""
    cand = (ref & ~0xFF) | low8
    if cand - ref > 128:
        cand -= 256
    elif ref - cand > 128:
        cand += 256
    return cand


class Stream:
    def __init__(self, offer, receiver_ssrc, out_path=None):
        self.offer = offer
        self.kind = "video" if offer["type"] == "video_source" else "audio"
        self.codec = offer["codecName"]
        self.ssrc = offer["ssrc"]
        self.receiver_ssrc = receiver_ssrc
        self.key = bytes.fromhex(offer["aesKey"])
        self.iv_mask = bytes.fromhex(offer["aesIvMask"])
        self.target_delay = offer["targetDelay"] / 1000
        self.timebase = int(offer["timeBase"].split("/")[1])
        self.frames = {}                 # id -> {"packets": {pid: bytes}, "last": n, "key": bool, "rtp": ts, "first_seen": t}
        self.checkpoint = -1
        self.completed = 0
        self.keyframes = 0
        self.order_errors = 0
        self.decode_errors = 0
        self.late = 0
        self.sr = None                   # (ntp seconds float, rtp, arrival)
        self.sr_count = 0
        self.dropped_before_sr = 0
        self.packets = 0
        self.lost_sim = 0
        self.lost = set()                # (frame, packet) dropped by --loss and not yet seen
        self.recovered = 0               # ... that arrived later (retransmitted)
        self.retransmits_seen = 0
        self.max_seen = -1
        self.highest_seq = None
        self.out = open(out_path, "wb") if out_path else None
        self.first_key_ok = None
        self.frame_bytes = 0

    def decrypt(self, frame_id, data):
        nonce = bytearray(self.iv_mask)
        fid = struct.pack(">I", frame_id & 0xFFFFFFFF)
        for i in range(4):
            nonce[8 + i] ^= fid[i]
        dec = Cipher(algorithms.AES(self.key), modes.CTR(bytes(nonce))).decryptor()
        return dec.update(data) + dec.finalize()


class MediaProtocol(asyncio.DatagramProtocol):
    def __init__(self, sink):
        self.sink = sink

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        self.sink.on_udp(data, addr, self.transport)


class MockCast:
    def __init__(self, a):
        self.a = a
        self.ok = False
        self.done = asyncio.Event()
        self.streams = {}          # sender ssrc -> Stream
        self.sender_addr = None
        self.udp = None
        self.writer = None
        self.sender_id = None
        self.app_running = False
        self.answered_at = None
        self.feedback_count = 0
        self.stop_received = False
        self.pli_sent_at = None
        self.pli_honoured = None

    # ------------------------------------------------------------ control

    def send(self, source, dest, ns, payload):
        if ns != NS_HEARTBEAT:
            log("Cast", f"-> {ns.split(':')[-1]} {payload.get('type') or payload.get('responseType')}")
        self.writer.write(encode_message(source, dest, ns, payload))

    def receiver_status(self, dest, request_id=0):
        apps = []
        if self.app_running:
            apps.append({"appId": MIRRORING_APP, "displayName": "Chrome Mirroring", "isIdleScreen": False,
                         "sessionId": "8b7e7cd2-6f53-4d1e-9f13-mock", "statusText": "Mirroring",
                         "transportId": TRANSPORT_ID,
                         "namespaces": [{"name": NS_WEBRTC}, {"name": "urn:x-cast:com.google.cast.remoting"}]})
        self.send("receiver-0", dest, NS_RECEIVER, {"type": "RECEIVER_STATUS", "requestId": request_id,
                                                    "status": {"applications": apps,
                                                               "volume": {"level": 1.0, "muted": False}}})

    async def on_tls(self, reader, writer):
        if self.writer is not None:
            writer.close()
            return
        self.writer = writer
        log("Cast", f"Sender connected (TLS {writer.get_extra_info('ssl_object').version()})")
        buf = b""
        try:
            while True:
                hdr = await reader.readexactly(4)
                n = struct.unpack(">I", hdr)[0]
                assert n <= 65536, "message too large"
                m = decode_message(await reader.readexactly(n))
                self.handle(m)
        except asyncio.IncompleteReadError:
            log("Cast", "Sender closed the TLS connection")
        except AssertionError as e:
            log("FAIL", f"Protocol violation: {e}")
            self.ok = False
        finally:
            await asyncio.sleep(0.2)
            self.done.set()

    def handle(self, m):
        p, ns = m["payload"] or {}, m["ns"]
        t = p.get("type")
        if ns == NS_HEARTBEAT:
            if t == "PING":
                self.send(m["dest"], m["source"], NS_HEARTBEAT, {"type": "PONG"})
            return
        log("Cast", f"<- {ns.split(':')[-1]} {t} from {m['source']} to {m['dest']}")
        if ns == NS_CONNECTION:
            if t == "CONNECT" and m["dest"] == TRANSPORT_ID:
                self.sender_id = m["source"]
            return
        if ns == NS_RECEIVER:
            if t == "LAUNCH":
                assert p.get("appId") == MIRRORING_APP, f"unexpected appId {p.get('appId')}"
                if self.a.launch_error:
                    self.send("receiver-0", m["source"], NS_RECEIVER,
                              {"type": "LAUNCH_ERROR", "requestId": p.get("requestId"), "reason": "NOT_ALLOWED"})
                    return
                self.app_running = True
                self.receiver_status(m["source"], p.get("requestId", 0))
            elif t == "GET_STATUS":
                self.receiver_status(m["source"], p.get("requestId", 0))
            elif t == "STOP":
                self.stop_received = True
                self.app_running = False
                self.receiver_status("*", p.get("requestId", 0))
                log("Cast", "Sender stopped the mirroring app")
            return
        if ns == NS_WEBRTC and t == "OFFER":
            assert m["dest"] == TRANSPORT_ID, "OFFER must go to the app's transportId"
            self.answer(m, p)

    def answer(self, m, p):
        offer = p["offer"]
        assert offer.get("castMode") == "mirroring"
        streams = offer["supportedStreams"]
        for s in streams:
            for k in ("index", "type", "codecName", "rtpProfile", "rtpPayloadType", "ssrc", "aesKey", "aesIvMask", "timeBase"):
                assert k in s, f"stream {s.get('index')} lacks {k}"
            assert len(s["aesKey"]) == 32 and len(s["aesIvMask"]) == 32
            assert s["rtpProfile"] == "cast"
        want_video = self.a.video_codecs.split(",")
        video = next((s for c in want_video for s in streams if s["type"] == "video_source" and s["codecName"] == c), None)
        audio = next((s for c in self.a.audio_codecs.split(",") for s in streams
                      if s["type"] == "audio_source" and s["codecName"] == c), None) if self.a.audio_codecs else None
        assert video, f"no acceptable video stream in OFFER ({[s['codecName'] for s in streams]})"
        picked = [s for s in (audio, video) if s]
        ssrcs = [random.randint(1, 0x7FFFFFFF) for _ in picked]
        for s, r in zip(picked, ssrcs):
            out = self.a.out if s is video else None
            self.streams[s["ssrc"]] = Stream(s, r, out)
        w, h = self.a.max_size.split("x")
        answer = {
            "udpPort": self.a.udp_port,
            "sendIndexes": [s["index"] for s in picked],
            "ssrcs": ssrcs,
            "constraints": {
                "video": {"maxPixelsPerSecond": int(w) * int(h) * 30.0, "maxDimensions":
                          {"width": int(w), "height": int(h), "frameRate": "30"},
                          "maxBitRate": self.a.max_bitrate, "maxDelay": 1500},
                "audio": {"maxSampleRate": 48000, "maxChannels": 2, "maxBitRate": 256000},
            },
            "display": {"dimensions": {"width": 1920, "height": 1080, "frameRate": "60"}, "scaling": "sender"},
            "receiverRtcpEventLog": [],
        }
        self.send(TRANSPORT_ID, m["source"], NS_WEBRTC,
                  {"type": "ANSWER", "seqNum": p.get("seqNum"), "result": "ok", "answer": answer})
        self.answered_at = time.monotonic()
        log("Cast", "Picked " + " + ".join(f"{s['codecName']} (target delay {s['targetDelay']} ms)" for s in picked))
        self.ok = True
        if self.a.pli_at:
            asyncio.get_event_loop().call_later(self.a.pli_at, self.send_pli)
        if self.a.duration:
            asyncio.get_event_loop().call_later(self.a.duration, self.app_stopped_on_tv)

    def app_stopped_on_tv(self):
        log("Cast", f"{self.a.duration}s elapsed - stopping the app (as if stopped on the TV)")
        self.app_running = False
        self.receiver_status("*")
        asyncio.get_event_loop().call_later(1.0, self.done.set)

    # ------------------------------------------------------------- media

    def on_udp(self, data, addr, transport):
        self.sender_addr = addr
        self.udp = transport
        if len(data) >= 8 and 200 <= data[1] <= 207:
            self.on_rtcp(data)
            return
        if len(data) < 18 or data[0] != 0x80:
            log("FAIL", "bad RTP packet")
            self.ok = False
            return
        ssrc = struct.unpack(">I", data[8:12])[0]
        s = self.streams.get(ssrc)
        if not s:
            return
        fid_peek = expand(data[13], max(s.max_seen, 0))
        pid_peek = struct.unpack(">H", data[14:16])[0]
        if self.a.loss and random.random() < self.a.loss / 100:
            s.lost_sim += 1
            if fid_peek > s.checkpoint:
                s.lost.add((fid_peek, pid_peek))
            return
        if (fid_peek, pid_peek) in s.lost:
            s.lost.discard((fid_peek, pid_peek))
            s.recovered += 1
        s.packets += 1
        pt = data[1] & 0x7F
        marker = bool(data[1] & 0x80)
        rtp_ts = struct.unpack(">I", data[4:8])[0]
        b12 = data[12]
        key = bool(b12 & 0x80)
        has_ref = bool(b12 & 0x40)
        ext_count = b12 & 0x3F
        fid = expand(data[13], max(s.max_seen, 0))
        pid, last = struct.unpack(">HH", data[14:18])
        off = 18
        if has_ref:
            ref = expand(data[18], fid)
            off = 19
            if key and ref != fid:
                log("FAIL", f"key frame {fid} references {ref}")
                self.ok = False
            if not key and s.kind == "video" and ref != fid - 1:
                s.order_errors += 1
        for _ in range(ext_count):
            hdr = struct.unpack(">H", data[off:off + 2])[0]
            off += 2 + (hdr & 0x3FF)
        if marker != (pid == last):
            log("FAIL", f"marker bit wrong on frame {fid} packet {pid}/{last}")
            self.ok = False
        expected_pt = 96 if s.kind == "video" else 127
        if pt != expected_pt:
            log("FAIL", f"{s.kind} payload type {pt}, expected {expected_pt}")
            self.ok = False
        if s.sr is None and pid == 0:
            s.dropped_before_sr += 1     # the receiver can't place it in time yet
            return
        if fid <= s.checkpoint:
            s.retransmits_seen += 1
            return
        s.max_seen = max(s.max_seen, fid)
        f = s.frames.setdefault(fid, {"packets": {}, "last": last, "key": key, "rtp": rtp_ts,
                                      "first_seen": time.monotonic()})
        if pid in f["packets"]:
            s.retransmits_seen += 1
        f["packets"][pid] = data[off:]
        self.advance(s)

    def advance(self, s):
        progressed = False
        while True:
            f = s.frames.get(s.checkpoint + 1)
            if not f or len(f["packets"]) != f["last"] + 1:
                break
            fid = s.checkpoint + 1
            payload = b"".join(f["packets"][i] for i in range(f["last"] + 1))
            plain = s.decrypt(fid, payload)
            s.frame_bytes += len(plain)
            if f["key"]:
                s.keyframes += 1
                if self.pli_sent_at and self.pli_honoured is None and s.kind == "video":
                    self.pli_honoured = time.monotonic() - self.pli_sent_at
            if s.kind == "video":
                if not plain.startswith(b"\x00\x00\x00\x01"):
                    s.decode_errors += 1
                if fid == 0:
                    s.first_key_ok = f["key"]
                if s.out:
                    s.out.write(plain)
            else:
                if s.codec == "aac" and plain[:2] == b"\xff\xf1":
                    s.decode_errors += 1          # must be raw AAC, not ADTS
                if s.codec == "opus" and not plain:
                    s.decode_errors += 1
            # Playout deadline: capture time (via the sender report) + target delay.
            if s.sr:
                ntp_sr, rtp_sr, _ = s.sr
                d = ((f["rtp"] - rtp_sr + 2**31) % 2**32 - 2**31) / s.timebase
                capture_wall = ntp_sr + d
                if time.time() > capture_wall + s.target_delay + self.a.timing_tolerance_ms / 1000:
                    s.late += 1
            del s.frames[fid]
            s.checkpoint = fid
            s.completed += 1
            progressed = True
        if progressed:
            self.feedback(s)

    def on_rtcp(self, data):
        if data[1] != 200:
            return
        ssrc = struct.unpack(">I", data[4:8])[0]
        s = self.streams.get(ssrc)
        if not s:
            return
        ntp_hi, ntp_lo, rtp = struct.unpack(">IIII", data[8:24])[:3]
        s.sr = (ntp_hi - NTP_EPOCH + ntp_lo / 2**32, rtp, time.monotonic(), )
        s.sr_mid = ((ntp_hi & 0xFFFF) << 16) | (ntp_lo >> 16)
        s.sr_count += 1

    def feedback(self, s, nacks=()):
        if not self.udp:
            return
        # Receiver report with a report block about the sender (LSR/DLSR for its RTT).
        lsr = getattr(s, "sr_mid", 0)
        dlsr = int((time.monotonic() - s.sr[2]) * 65536) if s.sr else 0
        lost_fraction = int(min(255, 256 * s.lost_sim / max(1, s.lost_sim + s.packets)))
        rr = struct.pack(">BBHI", 0x81, 201, 7, s.receiver_ssrc)
        rr += struct.pack(">IIIIII", s.ssrc, lost_fraction << 24, 0, 0, lsr, dlsr)
        # Cast feedback: checkpoint, NACK loss fields.
        loss = b"".join(struct.pack(">BHB", fid & 0xFF, pid, 0) for fid, pid in nacks[:255])
        body = struct.pack(">II4sBBH", s.receiver_ssrc, s.ssrc, b"CAST", s.checkpoint & 0xFF,
                           len(nacks[:255]), int(s.target_delay * 1000)) + loss
        fb = struct.pack(">BBH", 0x80 | 15, 206, len(body) // 4) + body
        self.feedback_count += 1
        self.udp.sendto(rr + fb, self.sender_addr)

    def send_pli(self):
        for s in self.streams.values():
            if s.kind == "video" and self.udp:
                body = struct.pack(">II", s.receiver_ssrc, s.ssrc)
                self.udp.sendto(struct.pack(">BBH", 0x80 | 1, 206, 2) + body, self.sender_addr)
                self.pli_sent_at = time.monotonic()
                log("Cast", "Sent picture loss indication")

    async def nack_loop(self):
        while not self.done.is_set():
            await asyncio.sleep(0.03)
            now = time.monotonic()
            for s in self.streams.values():
                nacks = []
                for fid in range(s.checkpoint + 1, s.max_seen + 1):
                    f = s.frames.get(fid)
                    if f is None:
                        nacks.append((fid, 0xFFFF))
                        continue
                    if now - f["first_seen"] < 0.02:
                        continue
                    for pid in range(f["last"] + 1):
                        if pid not in f["packets"]:
                            nacks.append((fid, pid))
                self.feedback(s, nacks)

    # ------------------------------------------------------------- run

    async def run(self):
        cert, key = make_cert()
        ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ctx.load_cert_chain(cert, key)
        server = await asyncio.start_server(self.on_tls, self.a.bind, self.a.port, ssl=ctx)
        loop = asyncio.get_event_loop()
        await loop.create_datagram_endpoint(lambda: MediaProtocol(self), local_addr=(self.a.bind, self.a.udp_port))
        log("Cast", f"Mock Cast receiver on {self.a.bind}:{self.a.port} (TLS), media UDP {self.a.udp_port}")
        adv = None
        if self.a.advertise:
            adv = subprocess.Popen(["dns-sd", "-R", "mock-cast-" + str(os.getpid()), "_googlecast._tcp", "local",
                                    str(self.a.port), f"fn={self.a.advertise}", "md=Mock Chromecast", "ca=4101"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        nl = asyncio.create_task(self.nack_loop())
        try:
            await asyncio.wait_for(self.done.wait(), self.a.timeout)
        except asyncio.TimeoutError:
            log("FAIL", "timeout")
            self.ok = False
        nl.cancel()
        server.close()
        if adv:
            adv.terminate()
        return self.report()

    def report(self):
        errs = []
        if not self.answered_at:
            errs.append("no OFFER/ANSWER exchange")
        for s in self.streams.values():
            log("Media", f"{s.kind} {s.codec}: {s.completed} frames ({s.keyframes} key), {s.packets} packets, "
                         f"{s.sr_count} sender reports, {s.retransmits_seen} duplicates/retransmits, "
                         f"{s.lost_sim} dropped by --loss ({s.recovered} recovered by retransmission), "
                         f"{s.dropped_before_sr} dropped before first SR, "
                         f"{s.late} late, {s.frame_bytes // 1024} KiB")
            if s.completed == 0:
                errs.append(f"no {s.kind} frames completed")
            if s.sr_count == 0:
                errs.append(f"no sender reports for {s.kind}")
            if s.decode_errors:
                errs.append(f"{s.decode_errors} {s.kind} frames failed sanity checks after decryption")
            if s.order_errors:
                errs.append(f"{s.order_errors} {s.kind} frames with a wrong reference frame")
            if s.kind == "video" and s.first_key_ok is False:
                errs.append("first video frame is not a key frame")
            if s.late > max(2, s.completed // 50):
                errs.append(f"{s.late} {s.kind} frames completed after their playout time")
            if self.a.loss and s.lost_sim >= 3 and s.recovered == 0:
                errs.append(f"{s.kind}: packets were lost but none was retransmitted")
            pending = len(s.frames)
            if pending > 3:
                errs.append(f"{pending} {s.kind} frames never completed (retransmission failed)")
        if self.a.pli_at:
            if self.pli_honoured is None:
                errs.append("no key frame after the picture loss indication")
            else:
                log("Media", f"Key frame {self.pli_honoured * 1000:.0f} ms after PLI")
        if self.a.expect_stop and not self.stop_received:
            errs.append("sender never sent STOP")
        for e in errs:
            log("FAIL", e)
        if self.ok and not errs:
            log("PASS", "Cast session completed and the media stream is valid")
            return 0
        if not self.ok:
            log("FAIL", "Cast session did not complete")
        return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8009)
    ap.add_argument("--udp-port", type=int, default=2344)
    ap.add_argument("--out", help="write the decrypted video elementary stream here")
    ap.add_argument("--duration", type=float, default=0, help="stop the app (as from the TV) after N s of streaming")
    ap.add_argument("--timeout", type=float, default=60)
    ap.add_argument("--video-codecs", default="h264", help="video codecs to accept, preferred first (h264,hevc)")
    ap.add_argument("--audio-codecs", default="opus,aac", help="audio codecs to accept, preferred first ('' = none)")
    ap.add_argument("--max-size", default="1920x1080")
    ap.add_argument("--max-bitrate", type=int, default=10_000_000)
    ap.add_argument("--loss", type=float, default=0, help="drop this %% of RTP packets (retransmission test)")
    ap.add_argument("--pli-at", type=float, default=0, help="send a picture loss indication after N s")
    ap.add_argument("--launch-error", action="store_true", help="refuse to launch the mirroring app")
    ap.add_argument("--expect-stop", action="store_true", help="fail unless the sender sends STOP")
    ap.add_argument("--timing-tolerance-ms", type=float, default=0)
    ap.add_argument("--advertise", metavar="NAME", help="register as _googlecast._tcp via dns-sd")
    a = ap.parse_args()
    sys.exit(asyncio.run(MockCast(a).run()))


if __name__ == "__main__":
    main()
