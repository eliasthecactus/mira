#!/usr/bin/env python3
"""
Mock Miracast-over-Infrastructure (MS-MICE) sink for testing Mira without hardware.

It behaves like a MICE receiver such as the Microsoft 4K Wireless Display Adapter:
  1. listens on TCP 7250 for SOURCE_READY
  2. connects back to the source's RTSP port and plays the sink side of WFD M1-M7
  3. receives RTP/MPEG-TS on UDP and validates it (RTP headers, sequence numbers,
     TS sync, continuity counters, PAT/PMT, PCR interval, PTS headroom)
  4. optionally writes the TS to a file and/or pipes it to ffplay

Exit status is 0 only if the handshake completed, media arrived, and no stream
errors were detected - so it doubles as an end-to-end test.

  python3 tools/mock_sink.py --duration 10 --out /tmp/mira.ts
  python3 tools/mock_sink.py --play            # watch it live with ffplay
"""
import argparse
import asyncio
import hashlib
import re
import random
import shutil
import unicodedata
import struct
import subprocess
import sys
import time

# What we claim to support in the M3 response. Modelled on typical Windows/MICE
# sinks: CBP+CHP up to level 4.2, CEA 640x480p60..1080p60, LPCM/AAC/AC3 audio.
DEFAULT_VIDEO_FORMATS = "00 00 03 10 0001ffff 1fffffff 00001fff 00 0000 0000 00 none none"
AUDIO_PROFILES = {
    "all": "LPCM 00000003 00, AAC 0000000f 00, AC3 00000007 00",
    "aac": "AAC 00000001 00",
    "lpcm": "LPCM 00000002 00",
    "none": "none",
}
LPCM_HEADER = bytes([0xA0, 0x06, 0x00, 0x11])
LPCM_PAYLOAD = 6 * 80 * 4

VIDEO_PID, AUDIO_PID, PMT_PID = 0x1011, 0x1100, 0x0100


def log(tag, msg):
    # ASCII-only output: transliterate names (e.g. curly apostrophes), replace the rest.
    text = unicodedata.normalize("NFKD", f"{time.strftime('%H:%M:%S')} [{tag}] {msg}")
    text = text.replace("\u2019", "'").replace("\u2018", "'").replace("\u201c", '"').replace("\u201d", '"')
    print(text.encode("ascii", "replace").decode("ascii"), flush=True)


# ---------------------------------------------------------------- MICE ----

def parse_mice(buf):
    """Returns (message, rest) or (None, buf) if incomplete."""
    if len(buf) < 4:
        return None, buf
    size, version, command = struct.unpack(">HBB", buf[:4])
    if len(buf) < size:
        return None, buf
    body = buf[4:size]
    return {"version": version, "command": command, "body": body, "tlvs": parse_tlvs(body), "size": size}, buf[size:]


def parse_tlvs(body):
    tlvs, i = {}, 0
    while i + 3 <= len(body):
        t, ln = struct.unpack(">BH", body[i:i + 3])
        tlvs[t] = body[i + 3:i + 3 + ln]
        i += 3 + ln
    return tlvs


def build_tlvs(items):
    return b"".join(struct.pack(">BH", t, len(v)) + v for t, v in items)


def build_mice(command, body):
    return struct.pack(">HBB", 4 + len(body), 1, command) + body


class DTLSServer:
    """Sink side of the MS-MICE DTLS exchange (pyOpenSSL with memory BIOs)."""

    def __init__(self):
        try:
            from OpenSSL import SSL
            from cryptography import x509
            from cryptography.hazmat.primitives import hashes, serialization
            from cryptography.hazmat.primitives.asymmetric import ec
        except ImportError:
            sys.exit("security modes need pyOpenSSL: python3 -m pip install pyopenssl cryptography")
        import datetime, tempfile, os
        self.SSL = SSL
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(x509.oid.NameOID.COMMON_NAME, "Mock MICE Sink")])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
                .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(days=1))
                .not_valid_after(now + datetime.timedelta(days=2)).sign(key, hashes.SHA256()))
        d = tempfile.mkdtemp()
        cp, kp = os.path.join(d, "c.pem"), os.path.join(d, "k.pem")
        open(cp, "wb").write(cert.public_bytes(serialization.Encoding.PEM))
        open(kp, "wb").write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                               serialization.NoEncryption()))
        ctx = SSL.Context(SSL.DTLS_METHOD)
        ctx.set_options(getattr(SSL, "OP_NO_QUERY_MTU", 0x00001000))
        ctx.use_certificate_file(cp)
        ctx.use_privatekey_file(kp)
        self.conn = SSL.Connection(ctx, None)
        self.conn.set_accept_state()
        try:
            self.conn.set_ciphertext_mtu(1400)
        except Exception:
            pass
        self.done = False
        self.decrypted = 0
        self.failed = 0

    def _drain(self):
        out = b""
        while True:
            try:
                out += self.conn.bio_read(65536)
            except self.SSL.WantReadError:
                return out

    def feed_handshake(self, token):
        self.conn.bio_write(token)
        try:
            self.conn.do_handshake()
            self.done = True
        except self.SSL.WantReadError:
            pass
        return self._drain()

    def decrypt(self, record):
        self.conn.bio_write(record)
        try:
            data = self.conn.recv(65536)
            self.decrypted += 1
            return data
        except (self.SSL.WantReadError, self.SSL.Error):
            self.failed += 1
            return None

    def encrypt(self, plaintext):
        self.conn.send(plaintext)
        return self._drain()

    def describe(self):
        return f"{self.conn.get_protocol_version_name()} {self.conn.get_cipher_name()}"


def socket_ip_bytes(ip):
    import ipaddress
    return ipaddress.ip_address(ip).packed


def decode_name(b):
    if b[:2] == b"\xff\xfe":
        return b[2:].decode("utf-16-le", "replace")
    if b[:2] == b"\xfe\xff":
        return b[2:].decode("utf-16-be", "replace")
    return b.decode("utf-16-le", "replace")


# ---------------------------------------------------------------- RTSP ----

class RTSPConn:
    def __init__(self, reader, writer):
        self.r, self.w = reader, writer
        self.cseq = 0

    async def read(self):
        head = await self.r.readuntil(b"\r\n\r\n")
        text = head.decode()
        lines = text.split("\r\n")
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        body = b""
        n = int(headers.get("content-length", "0"))
        if n:
            body = await self.r.readexactly(n)
        msg = {"start": lines[0], "headers": headers, "body": body.decode()}
        log("RTSP", f"<- {lines[0]}  {summarize(msg['body'])}")
        return msg

    def send(self, start, headers, body=""):
        out = start + "\r\n"
        for k, v in headers:
            out += f"{k}: {v}\r\n"
        if body:
            out += f"Content-Type: text/parameters\r\nContent-Length: {len(body.encode())}\r\n"
        out += "\r\n" + body
        self.w.write(out.encode())
        log("RTSP", f"-> {start}  {summarize(body)}")

    def request(self, method, uri, headers=(), body=""):
        self.cseq += 1
        self.send(f"{method} {uri} RTSP/1.0", [("CSeq", str(self.cseq))] + list(headers), body)
        return self.cseq

    def reply(self, msg, headers=(), body="", code="200 OK"):
        self.send(f"RTSP/1.0 {code}", [("CSeq", msg["headers"].get("cseq", "0"))] + list(headers), body)


def summarize(body):
    names = [l.split(":")[0].strip() for l in body.splitlines() if l.strip()]
    return f"[{', '.join(names)}]" if names else ""


def params(body):
    out = {}
    for line in body.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            out[k.strip().lower()] = v.strip()
        elif line.strip():
            out[line.strip().lower()] = ""
    return out


# ------------------------------------------------------- media validator ----

class MediaStats:
    def __init__(self, tolerance=0.0):
        self.tolerance = tolerance          # seconds of extra slack for slow CI machines
        self.rtp_packets = 0
        self.rtp_bytes = 0
        self.bad_pt = 0
        self.seq_gaps = 0
        self.last_seq = None
        self.last_ts = None
        self.ts_packets = 0
        self.sync_errors = 0
        self.cc = {}
        self.cc_errors = 0
        self.pids = {}
        self.pat = self.pmt = 0
        self.pcr_count = 0
        self.last_pcr = None            # (pcr seconds, arrival)
        self.max_pcr_gap = 0.0
        self.pes = {VIDEO_PID: 0, AUDIO_PID: 0}
        self.headroom = {VIDEO_PID: [], AUDIO_PID: []}
        self.first_packet = None
        self.keyframes = 0
        self.audio_stream_ids = set()
        self.lpcm_errors = 0
        self.dropped = 0
        self.decrypt_errors = 0
        self.encrypted_rtp = 0
        self.lossy = False

    def rtp(self, data):
        now = time.monotonic()
        if self.first_packet is None:
            self.first_packet = now
        if len(data) < 12 or data[0] >> 6 != 2:
            self.bad_pt += 1
            return b""
        pt = data[1] & 0x7F
        seq = struct.unpack(">H", data[2:4])[0]
        if pt != 33:
            self.bad_pt += 1
        if self.last_seq is not None and seq != (self.last_seq + 1) & 0xFFFF:
            self.seq_gaps += 1
        self.last_seq = seq
        self.rtp_packets += 1
        self.rtp_bytes += len(data)
        cc = data[0] & 0x0F
        payload = data[12 + 4 * cc:]
        if len(payload) % 188:
            self.sync_errors += 1
        for i in range(0, len(payload) - 187, 188):
            self.ts(payload[i:i + 188])
        return payload

    def ts(self, p):
        self.ts_packets += 1
        if p[0] != 0x47:
            self.sync_errors += 1
            return
        pusi = bool(p[1] & 0x40)
        pid = ((p[1] & 0x1F) << 8) | p[2]
        afc = (p[3] >> 4) & 3
        cc = p[3] & 0x0F
        self.pids[pid] = self.pids.get(pid, 0) + 1
        if afc & 1:
            if pid in self.cc and cc != (self.cc[pid] + 1) & 0x0F:
                self.cc_errors += 1
            self.cc[pid] = cc
        off = 4
        if afc & 2:
            af_len = p[4]
            if af_len > 0:
                flags = p[5]
                if flags & 0x40:
                    self.keyframes += 1
                if flags & 0x10:
                    b = p[6:12]
                    base = (b[0] << 25) | (b[1] << 17) | (b[2] << 9) | (b[3] << 1) | (b[4] >> 7)
                    ext = ((b[4] & 1) << 8) | b[5]
                    pcr = (base * 300 + ext) / 27e6
                    now = time.monotonic()
                    if self.last_pcr is not None:
                        self.max_pcr_gap = max(self.max_pcr_gap, pcr - self.last_pcr[0])
                    self.last_pcr = (pcr, now)
                    self.pcr_count += 1
            off += 1 + af_len
        if not (afc & 1) or not pusi:
            return
        payload = p[off:]
        if pid == 0:
            self.pat += 1
        elif pid == PMT_PID:
            self.pmt += 1
        elif pid in self.pes and payload[:3] == b"\x00\x00\x01" and payload[7] & 0x80:
            self.pes[pid] += 1
            if pid == AUDIO_PID:
                self.audio_stream_ids.add(payload[3])
                if payload[3] == 0xBD:
                    data = payload[9 + payload[8]:]
                    length = (payload[4] << 8) | payload[5]
                    if data[:4] != LPCM_HEADER or length != 3 + payload[8] + 4 + LPCM_PAYLOAD:
                        self.lpcm_errors += 1
            t = payload[9:14]
            pts = (((t[0] >> 1) & 7) << 30 | t[1] << 22 | (t[2] >> 1) << 15 | t[3] << 7 | t[4] >> 1) / 90000
            if self.last_pcr is not None:
                # Expected PCR "now" = last PCR + wall time since it arrived
                now_pcr = self.last_pcr[0] + (time.monotonic() - self.last_pcr[1])
                self.headroom[pid].append(pts - now_pcr)

    def errors(self):
        errs = []
        if self.rtp_packets == 0:
            errs.append("no RTP packets received")
        if self.bad_pt:
            errs.append(f"{self.bad_pt} RTP packets with wrong version/payload type")
        if self.decrypt_errors:
            errs.append(f"{self.decrypt_errors} RTP packets could not be decrypted")
        if self.lossy:
            return errs                          # gaps/late data are expected with --loss
        if self.seq_gaps:
            errs.append(f"{self.seq_gaps} RTP sequence gaps")
        if self.sync_errors:
            errs.append(f"{self.sync_errors} TS sync/size errors")
        if self.cc_errors:
            errs.append(f"{self.cc_errors} TS continuity errors")
        if self.rtp_packets and (self.pat == 0 or self.pmt == 0):
            errs.append("missing PAT/PMT")
        if self.rtp_packets and self.pcr_count == 0:
            errs.append("no PCR")
        if self.lpcm_errors:
            errs.append(f"{self.lpcm_errors} malformed LPCM PES")
        if self.max_pcr_gap > 0.1 + self.tolerance:
            errs.append(f"PCR gap {self.max_pcr_gap * 1000:.0f} ms (> {100 + self.tolerance * 1000:.0f} ms)")
        for pid, name in ((VIDEO_PID, "video"), (AUDIO_PID, "audio")):
            late = [h for h in self.headroom[pid] if h < -self.tolerance]
            if late:
                errs.append(f"{len(late)} {name} PES arrived after their PTS (late)")
        return errs

    def report(self, elapsed):
        def hr(pid):
            h = self.headroom[pid]
            return f"min {min(h) * 1000:.0f} / avg {sum(h) / len(h) * 1000:.0f} ms" if h else "n/a"
        mbps = self.rtp_bytes * 8 / max(elapsed, 0.001) / 1e6
        log("Media", f"{self.rtp_packets} RTP pkts ({mbps:.2f} Mbit/s), {self.ts_packets} TS pkts, "
                     f"PIDs {{{', '.join(f'0x{p:04x}:{n}' for p, n in sorted(self.pids.items()))}}}")
        if self.encrypted_rtp:
            log("Media", f"RTP was encrypted: {self.encrypted_rtp} DTLS records decrypted")
        if self.dropped:
            log("Media", f"Simulated loss: dropped {self.dropped} RTP packets")
        codec = {0xC0: "AAC", 0xBD: "LPCM"}
        log("Media", "audio stream: " + (", ".join(codec.get(i, hex(i)) for i in sorted(self.audio_stream_ids)) or "none"))
        log("Media", f"video PES {self.pes[VIDEO_PID]} (~{self.pes[VIDEO_PID] / max(elapsed, 0.001):.1f} fps, "
                     f"{self.keyframes} random-access), audio PES {self.pes[AUDIO_PID]}, PAT {self.pat}, PMT {self.pmt}")
        log("Media", f"PCR {self.pcr_count} (max gap {self.max_pcr_gap * 1000:.0f} ms); "
                     f"PTS headroom video {hr(VIDEO_PID)}, audio {hr(AUDIO_PID)}")


class RTPReceiver(asyncio.DatagramProtocol):
    def __init__(self, stats, sinks, sink):
        self.stats, self.sinks, self.sink = stats, sinks, sink

    def datagram_received(self, data, addr):
        if self.sink.a.loss and random.random() < self.sink.a.loss / 100:
            self.stats.dropped += 1
            return
        if self.sink.dtls and self.sink.dtls.done:
            data = self.sink.dtls.decrypt(data)
            if data is None:
                self.stats.decrypt_errors += 1
                return
            self.stats.encrypted_rtp += 1
        elif self.sink.dtls:
            self.stats.decrypt_errors += 1      # RTP before the handshake finished
            return
        self.sink.note_rtp(data)
        payload = self.stats.rtp(data)
        for s in self.sinks:
            try:
                s.write(payload)
            except (BrokenPipeError, ValueError):
                pass


# ---------------------------------------------------------------- main ----

class MockSink:
    def __init__(self, args):
        self.a = args
        self.done = asyncio.Event()
        self.ok = False
        self.stats = MediaStats(args.timing_tolerance_ms / 1000)
        self.sinks = []
        self.play_started = None
        self.mice_writer = None
        self.dtls = None
        self.session_options = 0
        self.pin = None
        self.pin_ok = False
        self.source_ip = None
        self.stats.lossy = bool(args.loss)
        # RTCP receiver reports
        self.rtcp_dest = None
        self.rr_ssrc = random.getrandbits(32)
        self.rtp_ssrc = None
        self.max_seq = None
        self.cycles = 0
        self.interval_received = 0
        self.interval_base = None

    async def run(self):
        loop = asyncio.get_running_loop()
        if self.a.out:
            self.sinks.append(open(self.a.out, "wb"))
        if self.a.play:
            if not shutil.which("ffplay"):
                sys.exit("ffplay not found (brew install ffmpeg)")
            p = subprocess.Popen(["ffplay", "-loglevel", "warning", "-fflags", "nobuffer", "-flags", "low_delay",
                                  "-framedrop", "-window_title", "Mira mock sink", "-f", "mpegts", "-"],
                                 stdin=subprocess.PIPE)
            self.sinks.append(p.stdin)
        await loop.create_datagram_endpoint(lambda: RTPReceiver(self.stats, self.sinks, self),
                                            local_addr=(self.a.bind, self.a.rtp_port))
        self.rtcp_transport, _ = await loop.create_datagram_endpoint(asyncio.DatagramProtocol,
                                                                     local_addr=(self.a.bind, self.a.rtp_port + 1))
        asyncio.create_task(self.send_receiver_reports())
        server = await asyncio.start_server(self.on_mice, self.a.bind, self.a.mice_port)
        log("MICE", f"Listening on {self.a.bind}:{self.a.mice_port}, RTP on UDP {self.a.rtp_port}")

        adv = None
        if self.a.advertise:
            adv = subprocess.Popen(["dns-sd", "-R", self.a.advertise, "_display._tcp", "local",
                                    str(self.a.mice_port), "container_id={6A1C9F5B-0000-4000-8000-4D4952414D4F}"],
                                   stdout=subprocess.DEVNULL)
            log("MICE", f"Advertising '{self.a.advertise}' as _display._tcp")

        try:
            await asyncio.wait_for(self.done.wait(), timeout=self.a.timeout)
        except asyncio.TimeoutError:
            log("Sink", f"Timed out after {self.a.timeout}s")
        finally:
            server.close()
            if adv:
                adv.terminate()
            for s in self.sinks:
                try:
                    s.close()
                except Exception:
                    pass

        elapsed = time.monotonic() - (self.stats.first_packet or time.monotonic())
        self.stats.report(elapsed)
        errs = self.stats.errors()
        for e in errs:
            log("FAIL", e)
        if self.ok and not errs:
            log("PASS", "handshake completed and media stream is valid")
            return 0
        if not self.ok:
            log("FAIL", "WFD session did not complete")
        return 1

    def mice_send(self, command, items, encrypt=False):
        body = build_tlvs(items)
        if encrypt:
            body = self.dtls.encrypt(body)
        self.mice_writer.write(build_mice(command, body))

    def secure_messages(self):
        # [MS-MICE] 3.1.5.5: after a SESSION_REQUEST, TLVArrays are encrypted once DTLS is up.
        return self.session_options and self.dtls and self.dtls.done

    async def on_mice(self, reader, writer):
        peer = writer.get_extra_info("peername")[0]
        self.source_ip = peer
        log("MICE", f"Source connected from {peer}")
        self.mice_writer = writer
        # Each signalling connection is a fresh attempt (a source may retry with PIN pairing).
        self.dtls = None
        self.session_options = 0
        self.pin_ok = False
        self.dtls_logged = False
        buf = b""
        while True:
            data = await reader.read(65536)
            if not data:
                log("MICE", "Source closed signalling connection")
                if self.ok:
                    self.done.set()
                return
            buf += data
            while True:
                msg, buf = parse_mice(buf)
                if not msg:
                    break
                if not self.handle_mice(msg, peer):
                    return

    def handle_mice(self, msg, peer):
        cmd = msg["command"]
        t = msg["tlvs"]
        if cmd in (1, 2, 5) and self.secure_messages():
            plain = self.dtls.decrypt(msg["body"])
            if plain is None:
                log("FAIL", f"could not decrypt TLVArray of command {cmd}")
                self.done.set()
                return False
            t = parse_tlvs(plain)
            log("MICE", f"   (TLVArray of command {cmd} decrypted: {len(msg['body'])} -> {len(plain)} bytes)")

        if cmd == 4:                                            # SESSION_REQUEST
            self.session_options = t.get(5, b"\x00")[0]
            log("MICE", f"<- SESSION_REQUEST name='{decode_name(t.get(0, b''))}' options=0x{self.session_options:02x}")
            if self.session_options & 0x02:
                self.pin = self.a.pin or "".join(random.choice("0123456789") for _ in range(8))
                log("MICE", f"   PIN shown on the TV: {self.pin}")
            if self.session_options & 0x02 and not self.session_options & 0x01:
                log("FAIL", "SinkDisplaysPin set without UseDtlsStreamEncryption (spec: bit A MUST be set)")
        elif cmd == 3:                                          # SECURITY_HANDSHAKE
            if self.dtls is None:
                self.dtls = DTLSServer()
                log("MICE", "<- SECURITY_HANDSHAKE (starting DTLS)")
            out = self.dtls.feed_handshake(t.get(4, b""))
            if out:
                self.mice_send(3, [(4, out)])
            if self.dtls.done and not getattr(self, "dtls_logged", False):
                self.dtls_logged = True
                log("MICE", f"   DTLS handshake complete: {self.dtls.describe()}")
        elif cmd == 5:                                          # PIN_CHALLENGE
            got = t.get(6, b"")
            ip = socket_ip_bytes(peer)
            expected = hashlib.sha256(self.pin.encode() + ip).digest() if self.pin else b""
            ok = got == expected
            log("MICE", f"<- PIN_CHALLENGE ({'correct' if ok else 'WRONG'} PIN hash)")
            self.mice_send(6, [(6, got), (3, t.get(3, b"")), (7, bytes([0 if ok else 1]))],
                           encrypt=bool(self.secure_messages()))
            self.pin_ok = ok
            if not ok:
                log("FAIL", "PIN hash mismatch")
        elif cmd == 1:                                          # SOURCE_READY
            name = decode_name(t.get(0, b""))
            port = struct.unpack(">H", t[2])[0] if 2 in t else None
            sid = t.get(3, b"").hex()
            log("MICE", f"<- SOURCE_READY v{msg['version']} name='{name}' rtsp_port={port} "
                        f"source_id={sid} ({msg['size']} bytes)")
            problems = []
            if msg["version"] != 1: problems.append("version != 1")
            if port is None: problems.append("missing RTSP_PORT TLV")
            if len(t.get(3, b"")) != 16: problems.append("SOURCE_ID is not 16 bytes")
            if 0 not in t: problems.append("missing FRIENDLY_NAME TLV")
            if problems:
                log("FAIL", "SOURCE_READY invalid: " + ", ".join(problems))
                self.done.set()
                return False
            if self.a.security == "pin" and not self.pin_ok:
                log("MICE", "   ignoring SOURCE_READY: this sink requires PIN pairing (--security pin)")
                return True
            if self.a.security == "encrypted" and not (self.dtls and self.dtls.done):
                log("MICE", "   ignoring SOURCE_READY: this sink requires encryption (--security encrypted)")
                return True
            asyncio.create_task(self.rtsp(peer, port))
        elif cmd == 2:
            log("MICE", f"<- STOP_PROJECTION name='{decode_name(t.get(0, b''))}'")
            if self.ok:
                self.done.set()
            else:
                log("MICE", "   (no session was running - waiting for the source to try again)")
                return False
        else:
            log("MICE", f"<- command {cmd} (ignored)")
        return True

    # RTCP receiver reports (RFC 3550 sec. 6.4.2), so the source's adaptive bitrate has data.
    def note_rtp(self, data):
        if len(data) < 12:
            return
        seq = struct.unpack(">H", data[2:4])[0]
        self.rtp_ssrc = struct.unpack(">I", data[8:12])[0]
        if self.max_seq is None:
            self.max_seq = seq
            self.interval_base = seq
        elif ((seq - self.max_seq) & 0xFFFF) < 0x8000:
            if seq < self.max_seq:
                self.cycles += 1 << 16
            self.max_seq = seq
        self.interval_received += 1

    async def send_receiver_reports(self):
        cumulative_lost = 0
        prev_ext = None
        while not self.done.is_set():
            await asyncio.sleep(1)
            if self.rtcp_dest is None or self.rtp_ssrc is None:
                continue
            ext = self.cycles + self.max_seq
            expected = ext - (prev_ext if prev_ext is not None else self.interval_base - 1)
            lost = max(0, expected - self.interval_received)
            cumulative_lost += lost
            fraction = min(255, (lost * 256) // expected) if expected > 0 else 0
            prev_ext = ext
            self.interval_received = 0
            rr = struct.pack(">BBHI", 0x81, 201, 7, self.rr_ssrc)
            rr += struct.pack(">IB", self.rtp_ssrc, fraction) + (cumulative_lost & 0xFFFFFF).to_bytes(3, "big")
            rr += struct.pack(">IIII", ext & 0xFFFFFFFF, 0, 0, 0)
            self.rtcp_transport.sendto(rr, self.rtcp_dest)
            if fraction:
                log("RTCP", f"-> RR: {fraction * 100 / 256:.1f}% lost")

    async def rtsp(self, host, port):
        try:
            reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port), 5)
        except Exception as e:
            log("FAIL", f"Cannot connect back to source RTSP {host}:{port}: {e}")
            self.done.set()
            return
        c = RTSPConn(reader, writer)
        session = None
        try:
            # M1 from source
            m1 = await c.read()
            assert m1["start"].startswith("OPTIONS"), "expected M1 OPTIONS"
            assert "org.wfa.wfd1.0" in m1["headers"].get("require", ""), "M1 lacks Require: org.wfa.wfd1.0"
            c.reply(m1, [("Public", "org.wfa.wfd1.0, SET_PARAMETER, GET_PARAMETER")])
            # M2 from us
            if not self.a.no_m2:
                seq = c.request("OPTIONS", "*", [("Require", "org.wfa.wfd1.0")])
                r = await c.read()
                assert r["start"].startswith("RTSP/1.0 200") and r["headers"].get("cseq") == str(seq), "bad M2 reply"
                pub = r["headers"].get("public", "")
                for m in ("org.wfa.wfd1.0", "SETUP", "PLAY", "TEARDOWN", "GET_PARAMETER", "SET_PARAMETER"):
                    assert m in pub, f"M2 Public lacks {m}"
            # M3
            m3 = await c.read()
            assert m3["start"].startswith("GET_PARAMETER"), "expected M3 GET_PARAMETER"
            req = [l.strip() for l in m3["body"].splitlines() if l.strip()]
            caps = {
                "wfd_video_formats": self.a.video_formats,
                "wfd_audio_codecs": AUDIO_PROFILES["none" if self.a.no_audio else self.a.audio],
                "wfd_client_rtp_ports": f"RTP/AVP/UDP;unicast {self.a.rtp_port} 0 mode=play",
                "wfd_content_protection": "none",
            }
            body = "".join(f"{k}: {caps[k]}\r\n" for k in req if k in caps)
            c.reply(m3, body=body)
            # M4
            m4 = await c.read()
            assert m4["start"].startswith("SET_PARAMETER"), "expected M4 SET_PARAMETER"
            p = params(m4["body"])
            for k in ("wfd_video_formats", "wfd_presentation_url", "wfd_client_rtp_ports"):
                assert k in p, f"M4 lacks {k}"
            log("Sink", f"M4 video: {p['wfd_video_formats']}")
            log("Sink", f"M4 audio: {p.get('wfd_audio_codecs', '(none)')}")
            assert str(self.a.rtp_port) in p["wfd_client_rtp_ports"], "M4 changed our RTP port"
            url = p["wfd_presentation_url"].split()[0]
            c.reply(m4)
            # M5 SETUP trigger
            m5 = await c.read()
            assert "wfd_trigger_method: SETUP" in m5["body"], "expected M5 SETUP trigger"
            c.reply(m5)
            # M6
            c.request("SETUP", url, [("Transport", f"RTP/AVP/UDP;unicast;client_port={self.a.rtp_port}")])
            r = await c.read()
            assert r["start"].startswith("RTSP/1.0 200"), "SETUP failed"
            session = r["headers"]["session"].split(";")[0]
            m = re.search(r"server_port=(\d+)(?:-(\d+))?", r["headers"].get("transport", ""))
            if m:
                self.rtcp_dest = (host, int(m.group(2) or int(m.group(1)) + 1))
            log("Sink", f"Session {session}, Transport: {r['headers'].get('transport')}")
            # M7
            c.request("PLAY", url, [("Session", session)])
            r = await c.read()
            assert r["start"].startswith("RTSP/1.0 200"), "PLAY failed"
            self.ok = True
            self.play_started = time.monotonic()
            log("Sink", "PLAY acknowledged - receiving media")
            if self.a.idr_at:
                asyncio.create_task(self.idr_later(c, session))
            if self.a.duration:
                asyncio.create_task(self.teardown_later(c, session))

            while True:
                m = await c.read()
                if m["start"].startswith("RTSP/1.0"):
                    continue
                c.reply(m, [("Session", session)] if session else [])
                if "wfd_trigger_method: TEARDOWN" in m["body"]:
                    c.request("TEARDOWN", url, [("Session", session)])
        except asyncio.IncompleteReadError:
            log("RTSP", "Source closed RTSP connection")
        except AssertionError as e:
            log("FAIL", f"Protocol violation: {e}")
            self.ok = False
        except Exception as e:
            log("FAIL", f"RTSP error: {e!r}")
            self.ok = False
        finally:
            await asyncio.sleep(0.3)
            self.done.set()

    async def idr_later(self, c, session):
        await asyncio.sleep(self.a.idr_at)
        before = self.stats.keyframes
        c.request("SET_PARAMETER", "rtsp://localhost/wfd1.0", [("Session", session)], "wfd_idr_request\r\n")
        await asyncio.sleep(0.5)
        if self.stats.keyframes > before:
            log("Sink", "IDR request honoured")
        elif self.a.loss:
            log("Sink", "IDR keyframe not seen (expected possible with --loss)")
        else:
            log("FAIL", "no keyframe within 500 ms of wfd_idr_request")
            self.ok = False

    async def teardown_later(self, c, session):
        await asyncio.sleep(self.a.duration)
        log("Sink", f"{self.a.duration}s elapsed - sending TEARDOWN")
        c.request("TEARDOWN", "rtsp://localhost/wfd1.0/streamid=0", [("Session", session)])
        await asyncio.sleep(0.5)
        self.done.set()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--mice-port", type=int, default=7250)
    ap.add_argument("--rtp-port", type=int, default=19100)
    ap.add_argument("--out", help="write received MPEG-TS to this file")
    ap.add_argument("--play", action="store_true", help="pipe received stream into ffplay")
    ap.add_argument("--duration", type=float, default=0, help="send TEARDOWN after N seconds of streaming")
    ap.add_argument("--timeout", type=float, default=120, help="give up after N seconds overall")
    ap.add_argument("--idr-at", type=float, default=0, help="send wfd_idr_request after N seconds")
    ap.add_argument("--audio", choices=sorted(AUDIO_PROFILES), default="all",
                    help="audio codecs to advertise (default: all = LPCM+AAC+AC3)")
    ap.add_argument("--no-audio", action="store_true", help="same as --audio none")
    ap.add_argument("--no-m2", action="store_true", help="don't send M2 OPTIONS (some sinks skip it)")
    ap.add_argument("--video-formats", default=DEFAULT_VIDEO_FORMATS, help="wfd_video_formats value to advertise")
    ap.add_argument("--advertise", metavar="NAME", help="register NAME as _display._tcp via dns-sd")
    ap.add_argument("--security", choices=["none", "encrypted", "pin"], default="none",
                    help="require MS-MICE security: plain SOURCE_READY is ignored until it's satisfied")
    ap.add_argument("--pin", help="PIN to 'display' (default: random 8 digits)")
    ap.add_argument("--loss", type=float, default=0, help="drop this %% of RTP packets and report it via RTCP")
    ap.add_argument("--timing-tolerance-ms", type=float, default=0,
                    help="extra slack for PCR gaps / late PES (CI VMs have no hardware encoder)")
    a = ap.parse_args()
    sys.exit(asyncio.run(MockSink(a).run()))


if __name__ == "__main__":
    main()
