# Local stand-in for the Shortcut REST API: logs each request and keeps story state.
import json, sys, http.server
LOG = sys.argv[2]; stories = {}; next_id = [9001]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def _rec(self, body):
        tok = self.headers.get('Shortcut-Token')
        with open(LOG,'a') as f:
            f.write(f"{self.command} {self.path} token={'ok' if tok=='tok-live-lab' else repr(tok)}\n")
            if body: f.write(f"  body: {body[:300]!r}\n")
    def _body(self):
        n = int(self.headers.get('Content-Length') or 0); return self.rfile.read(n).decode('utf-8','replace') if n else ''
    def do_GET(self):
        self._rec('')
        sid = self.path.rsplit('/',1)[-1]
        if sid in stories: return self._send(200, stories[sid])
        if sid == '6092': return self._send(200, {"id":6092,"workflow_state_id":500000008,"external_links":[]})
        self._send(404, {})
    def do_POST(self):
        b = self._body(); self._rec(b)
        if self.path == '/api/v3/stories':
            sid = str(next_id[0]); next_id[0]+=1
            d = json.loads(b); d.update(id=int(sid), app_url=f"https://app.shortcut.com/applypass/story/{sid}", external_links=[], comments=[])
            stories[sid] = d; return self._send(201, d)
        if self.path.endswith('/comments'):
            sid = self.path.split('/')[4]; stories.setdefault(sid,{}).setdefault('comments',[]).append(json.loads(b)['text']); return self._send(201, {})
        if self.path == '/api/v3/files': return self._send(201, [{}])
        self._send(404, {})
    def do_PUT(self):
        b = self._body(); self._rec(b)
        sid = self.path.rsplit('/',1)[-1]; stories.setdefault(sid,{"id":int(sid)}).update(json.loads(b)); self._send(200, stories[sid])
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
