# A stand-in for the GitHub commit status API (doc/spec/114 F114-14).
#   python3 github_stub.py <port> <log file>
# Every POST /repos/<owner>/<name>/statuses/<sha> is answered 201 and appended
# to the log as one JSON line {"path", "auth", "body"}.
import http.server, json, sys
LOG = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode()
        with open(LOG, "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization", ""),
                                "body": json.loads(body or "{}")}) + "\n")
        self.send_response(201); self.send_header("Content-Length", "2"); self.end_headers()
        self.wfile.write(b"{}")
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
