"""GCA sandbox relay. Runs on Netcup inside the Moyai image (reuses its Substrate client), because the
Substrate edge only admits Netcup's IP and Lambda / Cloud Run have changing egress IPs.

  GET  /health  -> {"status": "online"|"offline", "detail": "..."}
  POST /run     -> {files: {path: text}} -> harness result JSON   (one throw-away gVisor sandbox per call)
Auth: Authorization: Bearer <token from /run/gca-relay-token>. Bound to 127.0.0.1; Caddy exposes /gca-relay/ only."""
import asyncio
import hmac
import json
import os
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WORK = "/tmp/gca"
SLOTS = threading.BoundedSemaphore(int(os.environ.get("GCA_RELAY_SLOTS", "2")))  # cluster capacity = 2 sandboxes
TOKEN = ""
PROVIDER = None
REF = None


def parse(stdout: str) -> dict:
    for line in reversed(stdout.splitlines()):
        if line.startswith("GCA_RESULT:"):
            return json.loads(line[len("GCA_RESULT:"):])
    return {"status": "failed", "results": [{"request": "harness", "error": "no result from sandbox"}], "log": stdout[-1500:]}


async def health(provider=None):
    provider = provider or PROVIDER
    try:
        await asyncio.wait_for(provider.rpc("GetActorTemplate", {"actor_template": REF}, timeout=6), 9)
        return {"status": "online", "detail": "Substrate cluster reachable"}
    except Exception as e:
        return {"status": "offline", "detail": f"Substrate cluster unreachable ({type(e).__name__}); start it with moyai-up.sh"}


async def run(files: dict, provider=None) -> dict:
    provider = provider or PROVIDER
    t = time.time()
    sb = await provider.create(name="gca-test-" + uuid.uuid4().hex[:10], timeout=900)
    try:
        dirs = sorted({os.path.dirname(f"{WORK}/{p}") for p in files})
        proc = await sb.exec.aio("mkdir", "-p", *dirs, timeout=30)
        await asyncio.gather(proc.stdout.read.aio(), proc.stderr.read.aio())
        for path, text in files.items():
            await sb.filesystem.write_text.aio(text, f"{WORK}/{path}")
        proc = await sb.exec.aio("python3", f"{WORK}/harness.py", WORK, timeout=280)
        out, err = await asyncio.gather(proc.stdout.read.aio(), proc.stderr.read.aio())
        await proc.wait.aio()
        res = parse(out)
        if res.get("status") == "failed" and not res.get("results"):
            res["log"] = (err or "")[-1500:]
        res["relay_seconds"] = round(time.time() - t, 1)
        return res
    finally:
        await sb.terminate.aio()


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth(self):
        got = self.headers.get("authorization", "")
        if not TOKEN or not hmac.compare_digest(got, "Bearer " + TOKEN):
            self._send(401, {"error": "unauthorized"})
            return False
        return True

    def do_GET(self):
        if self.path.rstrip("/") == "/health" and self._auth():
            self._send(200, asyncio.run(health()))
        elif self.path.rstrip("/") != "/health":
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.rstrip("/") != "/run":
            return self._send(404, {"error": "not found"})
        if not self._auth():
            return
        n = int(self.headers.get("content-length", 0))
        if n > 400_000:
            return self._send(413, {"error": "too large"})
        files = json.loads(self.rfile.read(n)).get("files", {})
        if not SLOTS.acquire(timeout=60):
            return self._send(503, {"error": "all sandbox slots busy"})
        try:
            self._send(200, asyncio.run(run(files)))
        except Exception as e:
            self._send(200, {"status": "failed", "results": [{"request": "sandbox", "error": f"{type(e).__name__}: {e}"}]})
        finally:
            SLOTS.release()

    def log_message(self, *a):
        pass


def main():
    global TOKEN, PROVIDER, REF
    from app.config import Settings
    from app.sandboxes.substrate import SubstrateProvider, ref
    s = Settings()
    TOKEN = open(os.environ.get("GCA_RELAY_TOKEN_FILE", "/run/gca-relay-token")).read().strip()
    PROVIDER = SubstrateProvider(s)
    REF = ref(s.substrate_atespace, s.substrate_template)
    ThreadingHTTPServer(("0.0.0.0", 8798), Handler).serve_forever()


if __name__ == "__main__":
    main()
