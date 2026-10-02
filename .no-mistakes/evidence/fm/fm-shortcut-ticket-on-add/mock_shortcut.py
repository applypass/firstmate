# Local stand-in for the Shortcut REST API; logs every request to $LOG. Never reaches the real API.
import json, os, sys, re
from http.server import BaseHTTPRequestHandler, HTTPServer
LOG = os.environ["LOG"]; stories = {}; nxt = [9001]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0); return self.rfile.read(n) if n else b""
    def _send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _log(self, body):
        tok = "token=ok" if self.headers.get("Shortcut-Token") == "tok-lab-secret" else "token=MISSING"
        if self.headers.get("Content-Type","").startswith("multipart"): body = b"<multipart file upload %d bytes>" % len(body)
        with open(LOG, "a") as f: f.write(f"{self.command} {self.path} {tok} {body.decode(errors='replace')}\n")
    def do_GET(self):
        self._log(b""); m = re.match(r"/api/v3/stories/(\d+)$", self.path)
        if m and int(m.group(1)) in stories: return self._send(200, stories[int(m.group(1))])
        if m and int(m.group(1)) == 6092: return self._send(200, {"id":6092,"workflow_state_id":500000008,"external_links":[]})
        self._send(404, {})
    def do_POST(self):
        b = self._body(); self._log(b)
        if self.path == "/api/v3/stories":
            d = json.loads(b); i = nxt[0]; nxt[0] += 1
            stories[i] = {"id": i, "workflow_state_id": d.get("workflow_state_id"), "external_links": [], "app_url": f"https://app.shortcut.com/applypass/story/{i}"}
            return self._send(201, stories[i])
        self._send(200, {})
    def do_PUT(self):
        b = self._body(); self._log(b); m = re.match(r"/api/v3/stories/(\d+)$", self.path)
        if m and int(m.group(1)) in stories: stories[int(m.group(1))].update(json.loads(b))
        self._send(200, {})
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
