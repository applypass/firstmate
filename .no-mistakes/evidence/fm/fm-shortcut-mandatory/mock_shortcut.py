# Minimal local Shortcut API v3 stand-in for the live drive (no real Shortcut).
import json, sys, http.server, itertools
stories = {}; links = []; seq = itertools.count(9001)
LOG = open(sys.argv[2], "a")
class H(http.server.BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0); raw = self.rfile.read(n) if n else b""
        try: return json.loads(raw or b"{}")
        except Exception: return {}
    def log_message(self, *a): pass
    def handle_one(self, m):
        tok = self.headers.get("Shortcut-Token"); body = self._body() if m in ("POST","PUT") else {}
        LOG.write(f"{m} {self.path} token={'ok' if tok=='lab-dummy-token' else 'MISSING'} {json.dumps(body) if body else ''}\n"); LOG.flush()
        if tok != "lab-dummy-token": return self._send(401, {})
        p = self.path.split("?")[0]
        if m=="POST" and p=="/api/v3/stories":
            i = next(seq); s = dict(body, id=i, app_url=f"http://mock/story/{i}"); stories[i]=s; return self._send(201, s)
        if p.startswith("/api/v3/stories/") and p.count("/")==4:
            i = int(p.rsplit("/",1)[1])
            if i not in stories: return self._send(404, {})
            if m=="GET": return self._send(200, stories[i])
            if m=="PUT": stories[i].update(body); return self._send(200, stories[i])
        if m=="POST" and p=="/api/v3/story-links": links.append(body); return self._send(201, body)
        if m=="POST" and p.endswith("/comments"): return self._send(201, body)
        if m=="POST" and p=="/__seed":
            stories[body["id"]] = dict(body, app_url=f"http://mock/story/{body['id']}"); return self._send(201, {})
        return self._send(404, {})
    def do_GET(self): self.handle_one("GET")
    def do_POST(self): self.handle_one("POST")
    def do_PUT(self): self.handle_one("PUT")
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
