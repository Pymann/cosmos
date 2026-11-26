# Serves the bare repositories under GIT_PROJECT_ROOT over git smart HTTP
# (git http-backend), for run_e2e_git.sh (doc/spec/114).
# Minimal smart-HTTP git server: GIT_PROJECT_ROOT=<dir> python3 githttp.py <port>
import http.server, os, subprocess, sys
ROOT = os.environ["GIT_PROJECT_ROOT"]
class H(http.server.BaseHTTPRequestHandler):
    def run(self):
        path, _, query = self.path.partition("?")
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        env = dict(os.environ, GIT_PROJECT_ROOT=ROOT, GIT_HTTP_EXPORT_ALL="1", PATH_INFO=path,
                   QUERY_STRING=query, REQUEST_METHOD=self.command,
                   CONTENT_TYPE=self.headers.get("Content-Type", ""), CONTENT_LENGTH=str(len(body)),
                   GIT_PROTOCOL=self.headers.get("Git-Protocol", ""), REMOTE_ADDR="127.0.0.1")
        out = subprocess.run(["git", "http-backend"], input=body, env=env, capture_output=True).stdout
        head, _, rest = out.partition(b"\r\n\r\n")
        status = 200
        hdrs = []
        for line in head.split(b"\r\n"):
            k, _, v = line.decode().partition(":")
            if k.lower() == "status": status = int(v.strip().split()[0])
            elif k: hdrs.append((k, v.strip()))
        self.send_response(status)
        for k, v in hdrs: self.send_header(k, v)
        self.send_header("Content-Length", str(len(rest)))
        self.end_headers(); self.wfile.write(rest)
    do_GET = do_POST = run
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
