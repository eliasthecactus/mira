#!/usr/bin/env python3
"""
Mock hotel/venue casting gateway, for testing Mira's pairing.

Before pairing nothing listens on the Cast port (connections are refused, like the real
gateway). The web server offers pairing in one of three ways:
  --mode link      GET /pair?pairCode=<code> pairs (the link in the TV's QR code)
  --mode form      / shows a form; POST /activate with accessCode=<code> pairs
  --mode consent   the pairing page needs a checkbox ticked: only a person can finish
Once paired, the mock Cast receiver (tools/mock_cast.py) starts on the Cast port, and
this script exits with its result.

  python3 tools/mock_gateway.py --mode form --code 7F6GY -- --duration 6
"""
import argparse
import http.server
import os
import subprocess
import sys
import threading
import time
import urllib.parse

FORM_PAGE = """<html><body><h1>Hotel TV</h1><p>Enter the code shown on your TV.</p>
<form method="post" action="/activate"><input type="hidden" name="room" value="412">
<input name="accessCode" autocomplete="off"><input type="submit" name="go" value="Connect"></form></body></html>"""
CONSENT_PAGE = """<html><body><form method="post" action="/pair"><input type="hidden" name="pairCode" value="{code}">
<input type="checkbox" name="terms"> I accept the terms <button>Pair</button></form></body></html>"""


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} [Gateway] {msg}", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mode", choices=["link", "form", "consent"], default="link")
    ap.add_argument("--code", default="7F6GY")
    ap.add_argument("--web-port", type=int, default=8088)
    ap.add_argument("--cast-port", type=int, default=18009)
    ap.add_argument("--timeout", type=float, default=60)
    ap.add_argument("cast_args", nargs="*", help="arguments for mock_cast.py (after --)")
    a = ap.parse_args()

    paired = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, body, status=200):
            data = body.encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            u = urllib.parse.urlparse(self.path)
            q = urllib.parse.parse_qs(u.query)
            log(f"GET {u.path}")
            if a.mode == "link" and u.path == "/pair" and q.get("pairCode", [""])[0] == a.code:
                paired.set()
                self.reply("<html><body>Paired! You can cast now.</body></html>")
            elif a.mode == "form" and u.path in ("/", "/pair"):
                self.reply(FORM_PAGE)
            elif a.mode == "consent" and u.path in ("/", "/pair"):
                self.reply(CONSENT_PAGE.format(code=a.code))
            else:
                self.reply("<html><body>Scan the code on your TV.</body></html>", 404 if u.path != "/" else 200)

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
            q = urllib.parse.parse_qs(body)
            log(f"POST {self.path} fields {sorted(q)}")
            if a.mode == "form" and self.path == "/activate" and q.get("accessCode", [""])[0] == a.code \
                    and q.get("room") == ["412"]:
                paired.set()
                self.reply("<html><body>Paired!</body></html>")
            elif a.mode == "consent" and self.path == "/pair" and "terms" in q:
                paired.set()
                self.reply("<html><body>Paired!</body></html>")
            else:
                self.reply("<html><body>Wrong code.</body></html>", 403)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", a.web_port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    log(f"Pairing web page on :{a.web_port} ({a.mode}); Cast port {a.cast_port} closed until paired")
    if not paired.wait(a.timeout):
        log("FAIL: never paired")
        server.shutdown()
        sys.exit(2)
    log("Paired - opening the Cast port")
    py = sys.executable
    rc = subprocess.call([py, os.path.join(os.path.dirname(__file__), "mock_cast.py"),
                          "--port", str(a.cast_port), "--udp-port", "2345"] + a.cast_args)
    server.shutdown()
    sys.exit(rc)


if __name__ == "__main__":
    main()
