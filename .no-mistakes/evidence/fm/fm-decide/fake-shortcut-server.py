# Disposable local stand-in for the Shortcut REST API (records every request).
import json, sys, http.server, itertools
LOG = sys.argv[2]; ids = itertools.count(9001); cids = itertools.count(1)
class H(http.server.BaseHTTPRequestHandler):
    def _rec(self, body):
        with open(LOG, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "auth": self.headers.get("Shortcut-Token"), "body": body}) + "\n")
    def _send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); raw = self.rfile.read(n).decode()
        try: body = json.loads(raw)
        except Exception: body = raw
        self._rec(body)
        p = self.path.split("?")[0]
        if p == "/api/v3/stories":
            i = next(ids); return self._send(201, {"id": i, "app_url": f"https://app.shortcut.com/applypass/story/{i}"})
        if p.endswith("/comments"):
            sid = p.split("/")[4]
            if sid == "6666": return self._send(500, {"message": "boom"})
            c = next(cids); return self._send(201, {"id": c, "app_url": f"https://app.shortcut.com/applypass/story/{sid}#activity-{c}"})
        self._send(404, {})
    def do_GET(self): self._rec(None); self._send(200, {"id": 1})
    def do_PUT(self):
        n = int(self.headers.get("Content-Length") or 0); self._rec(self.rfile.read(n).decode()); self._send(200, {})
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
