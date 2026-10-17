"""Moyai sandbox: a Substrate gVisor sandbox on the Moyai GKE cluster, reached through the relay on
Netcup (the Substrate edge only admits Netcup's IP). Egress is limited to Moyai's allow-list."""
import json
import time
import urllib.request
from .. import config

NAME = "Moyai · Substrate gVisor (GKE)"
_cache = {"t": 0, "v": ("offline", "not checked")}


def _req(path, body=None, timeout=10):
    req = urllib.request.Request(config.MOYAI_RELAY_URL.rstrip("/") + path, method="POST" if body is not None else "GET",
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"authorization": f"Bearer {config.MOYAI_RELAY_TOKEN}", "content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def health():
    if not config.MOYAI_RELAY_URL or not config.MOYAI_RELAY_TOKEN:
        return "offline", "relay not configured"
    if time.time() - _cache["t"] < 30:
        return _cache["v"]
    try:
        h = _req("/health", timeout=14)
        v = (h.get("status", "offline"), h.get("detail", ""))
    except Exception as e:
        v = ("offline", f"relay unreachable ({type(e).__name__})")
    _cache.update(t=time.time(), v=v)
    return v


def run(files: dict) -> dict:
    try:
        return _req("/run", {"files": files}, timeout=600)
    except Exception as e:
        return {"status": "failed", "results": [{"request": "sandbox", "error": f"Moyai relay error: {type(e).__name__}: {e}"}]}
