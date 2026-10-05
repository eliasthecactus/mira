#!/usr/bin/env python3
"""
Mock DLNA media renderer (a "smart TV") for testing Mira's DLNA path without hardware.

  - answers SSDP M-SEARCH for urn:schemas-upnp-org:device:MediaRenderer:1
  - serves a device description with an AVTransport service
  - handles SetAVTransportURI / Play / Stop / GetTransportInfo (SOAP)
  - on Play, fetches the stream URL like a TV media player (a HEAD probe first, as
    many TVs do), checks the DLNA headers and the MPEG-TS packets, saves the stream
  - after --duration seconds "the user presses stop on the remote": state STOPPED

  python3 tools/mock_dlna.py --duration 8 --out /tmp/dlna.ts
  .build/debug/Mira connect 127.0.0.1 --dlna --test-pattern
"""
import argparse
import http.server
import socket
import struct
import sys
import threading
import time
import urllib.request
import xml.etree.ElementTree as ET

SSDP_ADDR, SSDP_PORT = "239.255.255.250", 1900
UDN = "uuid:6d0a3d0e-mock-dlna-0000-000000000001"


def log(tag, msg):
    print(f"{time.strftime('%H:%M:%S')} [{tag}] {msg}", flush=True)


DESCRIPTION = """<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>{name}</friendlyName>
    <manufacturer>Samsung Electronics</manufacturer>
    <modelName>Mock TV</modelName>
    <UDN>{udn}</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <controlURL>/upnp/control/RenderingControl1</controlURL>
        <eventSubURL>/upnp/event/RenderingControl1</eventSubURL>
        <SCPDURL>/RenderingControl.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/upnp/control/AVTransport1</controlURL>
        <eventSubURL>/upnp/event/AVTransport1</eventSubURL>
        <SCPDURL>/AVTransport.xml</SCPDURL>
      </service>
    </serviceList>
  </device>
</root>
"""


class State:
    def __init__(self, a):
        self.a = a
        self.transport_state = "NO_MEDIA_PRESENT"
        self.uri = None
        self.metadata = None
        self.errors = []
        self.ts_packets = 0
        self.sync_errors = 0
        self.bytes = 0
        self.head_ok = None
        self.stop_received = False
        self.fetching = False
        self.done = threading.Event()
        self.play_at = None
        self.pids = set()


def soap_response(action, body=""):
    return (f'<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            f's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
            f'<u:{action}Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">{body}'
            f'</u:{action}Response></s:Body></s:Envelope>')


def make_handler(state):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            if self.path == "/description.xml":
                body = DESCRIPTION.format(name=state.a.name, udn=UDN).encode()
                self.send_response(200)
                self.send_header("Content-Type", 'text/xml; charset="utf-8"')
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_error(404)

        def do_POST(self):
            action = self.headers.get("SOAPACTION", "").strip('"').split("#")[-1]
            body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
            log("TV", f"<- {action}")
            try:
                args = {el.tag.split("}")[-1]: (el.text or "") for el in ET.fromstring(body).iter()}
            except ET.ParseError as e:
                state.errors.append(f"malformed SOAP for {action}: {e}")
                self.send_error(500)
                return
            out = ""
            if action == "SetAVTransportURI":
                state.uri = args.get("CurrentURI")
                state.metadata = args.get("CurrentURIMetaData", "")
                if "object.item.videoItem" not in state.metadata or "protocolInfo" not in state.metadata:
                    state.errors.append("DIDL-Lite metadata lacks videoItem class or protocolInfo")
                state.transport_state = "STOPPED"
            elif action == "Play":
                if not state.uri:
                    state.errors.append("Play before SetAVTransportURI")
                state.transport_state = "TRANSITIONING"
                state.play_at = time.monotonic()
                threading.Thread(target=fetch, args=(state,), daemon=True).start()
            elif action == "Stop":
                state.stop_received = True
                state.transport_state = "STOPPED"
                state.done.set()
            elif action == "GetTransportInfo":
                out = (f"<CurrentTransportState>{state.transport_state}</CurrentTransportState>"
                       "<CurrentTransportStatus>OK</CurrentTransportStatus><CurrentSpeed>1</CurrentSpeed>")
            else:
                self.send_error(401)
                return
            data = soap_response(action, out).encode()
            self.send_response(200)
            self.send_header("Content-Type", 'text/xml; charset="utf-8"')
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    return Handler


def fetch(state):
    """What a TV media player does: probe with HEAD, then GET and play."""
    time.sleep(0.5)
    try:
        req = urllib.request.Request(state.uri, method="HEAD")
        with urllib.request.urlopen(req, timeout=5) as r:
            ct = r.headers.get("Content-Type")
            tm = r.headers.get("transferMode.dlna.org")
            state.head_ok = ct == "video/mpeg" and tm == "Streaming"
            if not state.head_ok:
                state.errors.append(f"HEAD headers: Content-Type={ct} transferMode={tm}")
    except Exception as e:
        state.errors.append(f"HEAD failed: {e}")
    out = open(state.a.out, "wb") if state.a.out else None
    written = 0
    last_video_start = 0     # byte offset of the newest video PES start
    try:
        with urllib.request.urlopen(state.uri, timeout=10) as r:
            if r.headers.get("contentFeatures.dlna.org") is None:
                state.errors.append("GET response lacks contentFeatures.dlna.org")
            state.transport_state = "PLAYING"
            state.fetching = True
            log("TV", f"Playing {state.uri}")
            started = time.monotonic()
            buf = b""

            while not state.done.is_set():
                chunk = r.read(65536)
                if not chunk:
                    log("TV", "Stream ended by the sender")
                    break
                state.bytes += len(chunk)
                buf += chunk
                while len(buf) >= 188:
                    pkt, buf = buf[:188], buf[188:]
                    state.ts_packets += 1
                    if pkt[0] != 0x47:
                        state.sync_errors += 1
                    else:
                        pid = ((pkt[1] & 0x1F) << 8) | pkt[2]
                        state.pids.add(pid)
                        if pid == 0x1011 and pkt[1] & 0x40:
                            last_video_start = written
                    if out:
                        out.write(pkt)
                    written += 188
                if state.a.duration and time.monotonic() - started > state.a.duration:
                    log("TV", f"{state.a.duration}s played - user presses stop on the remote")
                    state.transport_state = "STOPPED"
                    break
    except Exception as e:
        if not state.done.is_set():
            state.errors.append(f"stream fetch failed: {e}")
    finally:
        state.fetching = False
        if out:
            # Playback stopped mid-frame: keep only complete frames for the decode check.
            if last_video_start:
                out.truncate(last_video_start)
            out.close()
    # Keep answering GetTransportInfo; the sender should notice and end.
    if state.a.duration:
        threading.Timer(12, state.done.set).start()


def ssdp_responder(state, location):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    try:
        s.bind(("", SSDP_PORT))
    except OSError as e:
        log("TV", f"SSDP unavailable ({e}); connect with the description URL instead")
        return
    mreq = struct.pack("4s4s", socket.inet_aton(SSDP_ADDR), socket.inet_aton("0.0.0.0"))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    while not state.done.is_set():
        data, addr = s.recvfrom(4096)
        text = data.decode(errors="replace")
        if text.startswith("M-SEARCH") and "MediaRenderer" in text:
            reply = ("HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\n"
                     f"LOCATION: {location}\r\nSERVER: Mock/1.0 UPnP/1.0 MockTV/1.0\r\n"
                     "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n"
                     f"USN: {UDN}::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n")
            s.sendto(reply.encode(), addr)
            log("TV", f"SSDP reply to {addr[0]}:{addr[1]}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=49152)
    ap.add_argument("--name", default="Mock Samsung TV")
    ap.add_argument("--out", help="write the received MPEG-TS here")
    ap.add_argument("--duration", type=float, default=0, help="stop playback (as from the remote) after N s")
    ap.add_argument("--timeout", type=float, default=60)
    ap.add_argument("--expect-stop", action="store_true", help="fail unless the sender sends Stop")
    a = ap.parse_args()

    state = State(a)
    server = http.server.ThreadingHTTPServer((a.bind, a.port), make_handler(state))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    location = f"http://{a.bind}:{a.port}/description.xml"
    threading.Thread(target=ssdp_responder, args=(state, location), daemon=True).start()
    log("TV", f"Mock DLNA renderer '{a.name}' at {location}")

    if not state.done.wait(a.timeout):
        state.errors.append("timeout")
    time.sleep(0.5)
    server.shutdown()

    log("Media", f"{state.ts_packets} TS packets ({state.bytes // 1024} KiB), PIDs "
                 f"{sorted(hex(p) for p in state.pids)}, {state.sync_errors} sync errors")
    errs = list(state.errors)
    if state.uri is None:
        errs.append("no SetAVTransportURI")
    if state.ts_packets < 100:
        errs.append("hardly any media received")
    if state.sync_errors:
        errs.append(f"{state.sync_errors} TS sync errors")
    if state.head_ok is False:
        errs.append("HEAD response headers wrong")
    if a.expect_stop and not state.stop_received:
        errs.append("sender never sent Stop")
    for e in errs:
        log("FAIL", e)
    if not errs:
        log("PASS", "DLNA session completed and the stream is valid")
    sys.exit(1 if errs else 0)


if __name__ == "__main__":
    main()
