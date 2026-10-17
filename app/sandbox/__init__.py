"""Pluggable sandboxes for testing generated code. Generated code NEVER runs inside the chat server.

default: AgentCore Code Interpreter (AWS) / Cloud Run job with a no-permission SA and no internet (GCP)
moyai:   a Substrate gVisor sandbox on the Moyai GKE cluster, through the Netcup relay"""
import json
import time
from pathlib import Path
from .. import config

HARNESS = (Path(__file__).parent / "harness.py").read_text()
MAX_BUNDLE = 200_000  # bytes of source; generated apps are small


def bundle(ws: Path, test: dict, requests: list) -> dict:
    """Files to ship into the sandbox: the app root, the harness and a spec."""
    root = ws / test["root"]
    files = {}
    for p in sorted(root.rglob("*")):
        if p.is_file() and "__pycache__" not in p.parts and p.suffix not in (".zip", ".pyc"):
            files[f"{test['root']}/{p.relative_to(root)}"] = p.read_text(errors="replace")
    files["harness.py"] = HARNESS
    files["spec.json"] = json.dumps({**test, "requests": requests})
    if sum(len(v) for v in files.values()) > MAX_BUNDLE:
        raise ValueError("app is too large to test in the sandbox (200 KB of source max)")
    return files


def parse(stdout: str) -> dict:
    for line in reversed(stdout.splitlines()):
        if line.startswith("GCA_RESULT:"):
            return json.loads(line[len("GCA_RESULT:"):])
    return {"status": "failed", "results": [{"request": "harness", "error": "no result from sandbox"}], "log": stdout[-1500:]}


def backends() -> dict:
    from . import agentcore, cloudrun_job, moyai
    default = agentcore if config.CLOUD == "aws" else cloudrun_job
    return {"default": default, "moyai": moyai}


def status() -> list[dict]:
    out = []
    for key, mod in backends().items():
        st, detail = mod.health()
        out.append({"id": key, "label": "Default" if key == "default" else "Moyai", "backend": mod.NAME,
                    "status": st, "detail": detail})
    return out


# Packages already installed in the Default sandbox of each cloud (it has no internet to install more).
PREINSTALLED = {
    "aws": {"flask", "fastapi", "requests", "boto3", "botocore", "uvicorn"},
    "gcp": {"flask", "fastapi", "requests", "uvicorn", "google-cloud-firestore", "google-cloud-storage"},
}


def extra_packages(ws: Path, test: dict) -> list[str]:
    """requirements.txt entries the Default sandbox does not already have."""
    import re
    req = ws / test["root"] / "requirements.txt"
    if not req.exists():
        return []
    have = PREINSTALLED[config.CLOUD]
    out = []
    for line in req.read_text().splitlines():
        line = line.split("#")[0].strip()
        if not line or line.startswith("-"):
            continue
        name = re.split(r"[<>=!~\[; ]", line, maxsplit=1)[0].lower().replace("_", "-")
        if name not in have:
            out.append(name)
    return out


def _try(key: str, ws: Path, test: dict, requests: list):
    mod = backends()[key]
    st, detail = mod.health()
    if st != "online":
        return None, mod, detail
    t = time.time()
    res = mod.run(bundle(ws, test, requests))
    res.update(sandbox=mod.NAME, seconds=round(time.time() - t, 1))
    return res, mod, ""


def run(ws: Path, test: dict, requests: list, force_moyai: bool = False) -> dict:
    """Pick the sandbox, run, and say why. Rules:
    forced   -> Moyai only; refuse if offline (never silently downgrade)
    packages -> Moyai if online (its allow-list reaches PyPI), else Default
    otherwise Default; if Default reports missing packages and Moyai is online, retry on Moyai."""
    moyai = backends()["moyai"]
    if force_moyai:
        res, mod, detail = _try("moyai", ws, test, requests)
        if res is None:
            return {"status": "unavailable", "sandbox": moyai.NAME, "routed": "forced", "detail": detail,
                    "reason": "session is forced to Moyai and Moyai is offline"}
        res["routed"], res["reason"] = "forced", "session forced to Moyai"
        return res
    extra = extra_packages(ws, test)
    if extra:
        res, mod, detail = _try("moyai", ws, test, requests)
        if res is not None:
            res["routed"], res["reason"] = "auto", "needs packages Default cannot install offline: " + ", ".join(extra)
            return res
        note = "needs " + ", ".join(extra) + f" but Moyai is offline ({detail}); used Default"
    else:
        note = "no extra packages needed"
    res, mod, detail = _try("default", ws, test, requests)
    res["routed"], res["reason"] = "auto", note
    if res.get("status") == "missing_packages":
        res2, _, _ = _try("moyai", ws, test, requests)
        if res2 is not None:
            res2["routed"], res2["reason"] = "auto", "Default lacked packages; retried on Moyai"
            return res2
    return res
