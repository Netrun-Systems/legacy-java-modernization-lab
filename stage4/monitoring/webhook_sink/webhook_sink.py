#!/usr/bin/env python3
"""Minimal Alertmanager webhook sink.
Persists every POSTed payload to /data/webhooks.jsonl with a UTC timestamp.
"""
import http.server
import json
import os
import sys
import datetime
from datetime import timezone
import pathlib

DATA_FILE = pathlib.Path("/data/webhooks.jsonl")
DATA_FILE.parent.mkdir(parents=True, exist_ok=True)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body) if body else {}
        except json.JSONDecodeError:
            payload = {"raw": body.decode(errors="replace")}
        entry = {
            "ts": datetime.datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "path": self.path,
            "payload": payload,
        }
        with DATA_FILE.open("a") as f:
            f.write(json.dumps(entry) + "\n")
        line = f"[{entry['ts']}] POST {self.path} status={payload.get('status','?')} alerts={len(payload.get('alerts',[]))}"
        sys.stdout.write(line + "\n")
        sys.stdout.flush()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok\n")

    def do_GET(self):
        try:
            lines = DATA_FILE.read_text().strip().splitlines() if DATA_FILE.exists() else []
        except Exception:
            lines = []
        body = "\n".join(lines[-20:]).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.end_headers()
        self.wfile.write(body + b"\n")

    def log_message(self, *a):
        pass  # suppress default noisy logging


if __name__ == "__main__":
    addr = ("0.0.0.0", int(os.environ.get("PORT", 5001)))
    srv = http.server.HTTPServer(addr, Handler)
    sys.stdout.write(f"webhook-sink listening on {addr[0]}:{addr[1]}, writing to {DATA_FILE}\n")
    sys.stdout.flush()
    srv.serve_forever()
