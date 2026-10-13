# Disposable local Shortcut API: stories/<id>.json, extlinks.tsv (url\tid), comments in story json; logs every call.
import json, os, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
D = sys.argv[1]; PORT = int(sys.argv[2])
def sp(i): return os.path.join(D, 'stories', f'{i}.json')
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def body(self):
        n = int(self.headers.get('Content-Length') or 0); return json.loads(self.rfile.read(n) or b'{}')
    def logc(self, extra=''):
        with open(os.path.join(D,'api.log'),'a') as f: f.write(f'{self.command} {self.path} token={"yes" if self.headers.get("Shortcut-Token") else "no"} {extra}\n')
    def do_GET(self):
        self.logc(); u = urllib.parse.urlparse(self.path)
        if u.path == '/api/v3/external-link/stories':
            link = urllib.parse.parse_qs(u.query)['external_link'][0]
            ids = [int(l.split('\t')[1]) for l in open(os.path.join(D,'extlinks.tsv')) if l.split('\t')[0] == link]
            return self.send(200, [{'id': i} for i in ids])
        if u.path.startswith('/api/v3/stories/'):
            i = u.path.rsplit('/',1)[1]
            if os.path.exists(sp(i)): return self.send(200, json.load(open(sp(i))))
        self.send(404, {})
    def do_PUT(self):
        b = self.body(); self.logc(json.dumps(b)); i = self.path.rsplit('/',1)[1]
        s = json.load(open(sp(i))); s.update(b); json.dump(s, open(sp(i),'w')); self.send(200, s)
    def do_POST(self):
        b = self.body(); self.logc(json.dumps(b))
        if self.path.endswith('/comments'):
            i = self.path.split('/')[-2]; s = json.load(open(sp(i)))
            s.setdefault('comments', []).append({'text': b['text']}); json.dump(s, open(sp(i),'w')); return self.send(201, {'id': 1})
        self.send(404, {})
HTTPServer(('127.0.0.1', PORT), H).serve_forever()
