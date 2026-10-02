# Local HTTP stand-in for the Shortcut v3 API, used only by the live lab drive.
import json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
stories = {}; nxt = [9000]; log = open(sys.argv[2], 'a', buffering=1)
for seed in sys.argv[3:]:
    num, desc = seed.split('=', 1); stories[int(num)] = {"id": int(num), "description": desc, "workflow_state_id": 500000006, "external_links": [], "app_url": f"https://app.shortcut.com/applypass/story/{num}"}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def _body(self):
        n = int(self.headers.get('Content-Length') or 0); raw = self.rfile.read(n) if n else b''
        try: return json.loads(raw or b'{}')
        except Exception: return {}
    def _log(self, body=None):
        tok = 'token=' + ('present' if self.headers.get('Shortcut-Token') else 'MISSING')
        log.write(f"{self.command} {self.path} {tok}" + (f" BODY {json.dumps(body)}" if body else '') + "\n")
    def do_GET(self):
        self._log(); p = self.path.rstrip('/').split('/')
        if self.path.startswith('/api/v3/stories/') and p[-1].isdigit() and int(p[-1]) in stories: return self._send(200, stories[int(p[-1])])
        self._send(404, {})
    def do_POST(self):
        b = self._body(); self._log(b)
        if self.path == '/api/v3/stories':
            n = nxt[0]; nxt[0] += 1; s = dict(b); s.update(id=n, app_url=f"https://app.shortcut.com/applypass/story/{n}", external_links=[]); stories[n] = s; return self._send(201, s)
        self._send(200, {})
    def do_PUT(self):
        b = self._body(); self._log(b); p = self.path.split('/')
        if p[-1].isdigit() and int(p[-1]) in stories: stories[int(p[-1])].update(b); return self._send(200, stories[int(p[-1])])
        self._send(404, {})
srv = ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H); srv.serve_forever()
