import functools
import os
from http.server import HTTPServer, SimpleHTTPRequestHandler

handler = functools.partial(SimpleHTTPRequestHandler, directory=os.path.join(os.path.dirname(__file__), "site"))
HTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8080"))), handler).serve_forever()
