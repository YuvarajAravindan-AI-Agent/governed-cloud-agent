import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

from google.cloud import firestore

db = firestore.Client(project=os.environ["GOOGLE_CLOUD_PROJECT"], database=os.environ["FIRESTORE_DATABASE"])


class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(obj).encode())

    def do_GET(self):
        self._send(200, [d.to_dict() | {"id": d.id} for d in db.collection("items").stream()])

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        db.collection("items").document(str(body.get("id", "1"))).set(body)
        self._send(201, {"stored": True})


HTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8080"))), H).serve_forever()
