#!/usr/bin/env python3
"""Minimal webhook receiver for Phase 3 testing.
Listens on 0.0.0.0:8080, logs every POST body to stdout and to /tmp/webhook.log.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from datetime import datetime, timezone

LOG_FILE = "/tmp/webhook.log"


class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        ts = datetime.now(timezone.utc).isoformat()
        try:
            payload = json.loads(body)
            pretty = json.dumps(payload, indent=2)
        except Exception:
            pretty = body.decode("utf-8", errors="replace")

        line = f"\n{'='*60}\n[{ts}] POST {self.path}\n{pretty}\n"
        print(line, flush=True)
        with open(LOG_FILE, "a") as f:
            f.write(line)

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

    def log_message(self, fmt, *args):
        pass  # suppress default Apache-style access log


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    print(f"Webhook receiver listening on 0.0.0.0:{port}", flush=True)
    print(f"Logging to {LOG_FILE}", flush=True)
    HTTPServer(("0.0.0.0", port), WebhookHandler).serve_forever()
