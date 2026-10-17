import os
from http.server import BaseHTTPRequestHandler, HTTPServer


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.end_headers()
        self.wfile.write(b"<h1>Hello from governed-cloud-agent on Cloud Run</h1>")


HTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8080"))), H).serve_forever()
