#!/usr/bin/env python3
"""Capture whatever Claude Code's `http` hooks actually POST. Loopback only."""
import json, os, sys, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 48879
LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hooks.log")

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _cap(self, method):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        rec = {
            "at": datetime.datetime.now().isoformat(timespec="milliseconds"),
            "method": method,
            "path": self.path,
            "headers": dict(self.headers.items()),
            "body_len": len(body),
        }
        try:
            rec["body_json"] = json.loads(body) if body else None
        except Exception as e:
            rec["body_raw"] = body.decode("utf-8", "replace")
            rec["body_parse_error"] = str(e)
        with open(LOG, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):  self._cap("POST")
    def do_PUT(self):   self._cap("PUT")
    def do_GET(self):   self._cap("GET")
    def log_message(self, *a): pass

if __name__ == "__main__":
    open(LOG, "a").close()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    print(f"listening on 127.0.0.1:{PORT} -> {LOG}", flush=True)
    srv.serve_forever()
