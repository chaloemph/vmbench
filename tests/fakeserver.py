"""Tiny local stand-in for GitHub releases, used by tests/test_get.sh and tests/test_release.sh. Standard library only.

  python3 -I tests/fakeserver.py ROOTDIR PORTFILE

Serves ROOTDIR on 127.0.0.1 (random port, written to PORTFILE once listening) and, for the "latest" lookup:
  /latest       redirects to /releases/tag/v9.9.9      (a repository with a release)
  /latest-none  redirects to /releases                 (a repository without any release)
Bound to the loopback address only; it is never started by anything but the tests.
"""
import http.server
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=sys.argv[1], **kw)

    def do_GET(self):
        if self.path == "/latest":
            self.send_response(302)
            self.send_header("Location", "/releases/tag/v9.9.9")
            self.end_headers()
        elif self.path == "/latest-none":
            self.send_response(302)
            self.send_header("Location", "/releases")
            self.end_headers()
        elif self.path.startswith("/releases"):
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            super().do_GET()

    do_HEAD = do_GET

    def log_message(self, *args):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[2], "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
