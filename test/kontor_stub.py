#!/usr/bin/env python3
"""Ersatz fuer kontors generisches Repository, nur fuer die Abnahme
deploy/server/test_install.sh (doc/spec/112 §112.7).

Das echte kontor ist ein privates Repository und im CI-Job von cosmos nicht
ladbar.  Nachgebildet ist genau der Teil, den die Server-Einrichtung benutzt
(kontor README, „API"):

  PUT /generic/<pfad>   Bearer-Token noetig (Rolle writer); X-Checksum-Sha256
                        wird geprueft, wenn mitgeschickt
  GET /generic/<pfad>   anonym (auth.anonymous: reader)
  GET /api/v1/health

Jeder PUT steht als eine Zeile „PUT <pfad> <sha256>" in <daten>/puts.log —
daran sieht die Abnahme, dass ein unveraenderter Lauf nichts hochlaedt.

  kontor_stub.py <port> <daten-verzeichnis> <token-datei>
"""
import hashlib
import http.server
import os
import sys

PORT = int(sys.argv[1])
DATA = os.path.abspath(sys.argv[2])
TOKEN = open(sys.argv[3]).read().strip()
os.makedirs(os.path.join(DATA, "generic"), exist_ok=True)


def target(path):
    for prefix in ("/api/v1/generic/", "/generic/"):
        if path.startswith(prefix):
            rel = path[len(prefix):]
            break
    else:
        return None
    parts = [p for p in rel.split("/") if p]
    if not parts or any(p in (".", "..") for p in parts):
        return None
    return os.path.join(DATA, "generic", *parts)


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body=b"", ctype="application/json", digest=""):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        if digest:  # wie kontor: send_blob setzt x-checksum-sha256
            self.send_header("x-checksum-sha256", digest)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/v1/health":
            return self.reply(200, b'{"status":"ok"}')
        dest = target(self.path)
        if dest is None or not os.path.isfile(dest):
            return self.reply(404, b'{"error":"not found","code":"not_found"}')
        with open(dest, "rb") as f:
            body = f.read()
        self.reply(200, body, "application/octet-stream", hashlib.sha256(body).hexdigest())

    do_HEAD = do_GET

    def do_PUT(self):
        if self.headers.get("Authorization", "") != "Bearer " + TOKEN:
            return self.reply(401, b'{"error":"unauthorized","code":"unauthorized"}')
        dest = target(self.path)
        if dest is None:
            return self.reply(400, b'{"error":"bad path","code":"bad_request"}')
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        digest = hashlib.sha256(body).hexdigest()
        want = self.headers.get("X-Checksum-Sha256", "")
        if want and want != digest:
            return self.reply(400, b'{"error":"checksum mismatch","code":"bad_request"}')
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest + ".part", "wb") as f:
            f.write(body)
        os.replace(dest + ".part", dest)
        with open(os.path.join(DATA, "puts.log"), "a") as log:
            log.write("PUT %s %s\n" % (self.path, digest))
        self.reply(201, ('{"sha256":"%s","size":%d}' % (digest, len(body))).encode())

    def log_message(self, fmt, *args):
        sys.stderr.write("[kontor-stub] " + (fmt % args) + "\n")


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
