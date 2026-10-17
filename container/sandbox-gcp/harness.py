"""Runs INSIDE the sandbox (stdlib only). Usage: python harness.py <workdir>
<workdir>/spec.json: {"kind": "lambda"|"server"|"static", "root": "app", "entry": "handler.py"|"main.py",
                      "requests": [{"method": "GET", "path": "/", "body": null}]}
Prints one line: GCA_RESULT:{json}"""
import importlib.util
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request

CLOUD_ERRORS = ("NoCredentialsError", "DefaultCredentialsError", "Unable to locate credentials",
                "could not automatically determine credentials", "NoRegionError", "PermissionDenied",
                "Missing or insufficient permissions", "403 Request had insufficient authentication scopes")
IMPORT_ERRORS = ("ModuleNotFoundError", "ImportError: cannot import name")


ALIASES = {"pyyaml": "yaml", "pillow": "PIL", "beautifulsoup4": "bs4", "scikit-learn": "sklearn", "python-dateutil": "dateutil",
           "google-cloud-firestore": "google.cloud.firestore", "google-cloud-storage": "google.cloud.storage",
           "python-dotenv": "dotenv", "opencv-python": "cv2"}


def missing_packages(text):
    import re
    out = []
    for line in text.splitlines():
        line = line.split("#")[0].strip()
        if not line or line.startswith("-"):
            continue
        name = re.split(r"[<>=!~\[; ]", line, 1)[0]
        mod = ALIASES.get(name.lower(), name.replace("-", "_"))
        try:
            importlib.util.find_spec(mod)
            ok = importlib.util.find_spec(mod) is not None
        except (ImportError, ValueError):
            ok = False
        if not ok:
            out.append(line)
    return out


def main(work):
    work = os.path.abspath(work)
    spec = json.load(open(os.path.join(work, "spec.json")))
    root = os.path.join(work, spec["root"])
    out = {"kind": spec["kind"], "syntax": [], "install": None, "results": [], "status": "passed", "log": ""}
    for dirpath, _, files in os.walk(root):
        for f in files:
            if f.endswith(".py"):
                p = os.path.join(dirpath, f)
                try:
                    compile(open(p).read(), os.path.relpath(p, root), "exec")
                except SyntaxError as e:
                    out["syntax"].append(f"{os.path.relpath(p, root)}:{e.lineno}: {e.msg}")
    if out["syntax"]:
        out["status"] = "failed"
        return out
    reqs = spec.get("requests") or [{"method": "GET", "path": "/"}]
    env = dict(os.environ)
    req_file = os.path.join(root, "requirements.txt")
    if os.path.exists(req_file):
        missing = missing_packages(open(req_file).read())
        if not missing:
            out["install"] = "all requirements already available in the sandbox"
        else:
            deps = os.path.join(work, ".deps")
            try:  # the sandbox has no internet by design: fail fast instead of hanging on retries
                p = subprocess.run([sys.executable, "-m", "pip", "install", "-q", "--disable-pip-version-check", "--retries", "0",
                                    "--timeout", "3", "--target", deps] + missing, capture_output=True, text=True, timeout=25)
                ok = p.returncode == 0
            except subprocess.TimeoutExpired:
                ok = False
            out["install"] = "ok" if ok else "not installable offline: " + ", ".join(missing)
            if ok:
                env["PYTHONPATH"] = deps + os.pathsep + env.get("PYTHONPATH", "")
                sys.path.insert(0, deps)
    if spec["kind"] == "lambda":
        run_lambda(root, spec.get("entry", "handler.py"), reqs, out)
    else:
        run_server(root, spec, reqs, out, env)
    if any(400 <= (r.get("status") or 0) < 500 for r in out["results"]):
        out["status"] = "partial"
    if any(r.get("error") for r in out["results"]) or any((r.get("status") or 0) >= 500 for r in out["results"]):
        out["status"] = "failed"
    blob = json.dumps(out["results"]) + out["log"]
    if any(m in blob for m in CLOUD_ERRORS):
        out["status"] = "needs_cloud"
    elif out["status"] == "failed" and (out["install"] or "").startswith("not installable") and any(m in blob for m in IMPORT_ERRORS):
        out["status"] = "missing_packages"
    return out


def run_lambda(root, entry, reqs, out):
    sys.path.insert(0, root)
    os.environ.setdefault("TABLE_NAME", "sandbox-table")
    os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
    try:
        spec = importlib.util.spec_from_file_location("handler", os.path.join(root, entry))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    except Exception as e:
        out["results"].append({"request": "import", "error": f"{type(e).__name__}: {e}"})
        return
    for r in reqs:
        path = r.get("path", "/")
        ev = {"version": "2.0", "rawPath": path.split("?")[0], "rawQueryString": path.partition("?")[2],
              "requestContext": {"http": {"method": r.get("method", "GET"), "path": path.split("?")[0]}},
              "headers": {"content-type": "application/json"}, "body": r.get("body"), "isBase64Encoded": False}
        try:
            resp = mod.handler(ev, None)
            out["results"].append({"request": f"{r.get('method', 'GET')} {path}", "status": resp.get("statusCode"),
                                   "body": str(resp.get("body"))[:400]})
        except Exception as e:
            out["results"].append({"request": f"{r.get('method', 'GET')} {path}", "error": f"{type(e).__name__}: {e}"})


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def run_server(root, spec, reqs, out, env):
    port = free_port()
    env.update(PORT=str(port), GOOGLE_CLOUD_PROJECT=env.get("GOOGLE_CLOUD_PROJECT", "sandbox"),
               FIRESTORE_DATABASE=env.get("FIRESTORE_DATABASE", "sandbox"))
    if spec["kind"] == "static":
        cmd = [sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1", "--directory", root]
    else:
        cmd = [sys.executable, spec.get("entry", "main.py")]
    proc = subprocess.Popen(cmd, cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    up = False
    for _ in range(300):
        if proc.poll() is not None:
            break
        try:
            socket.create_connection(("127.0.0.1", port), 0.2).close()
            up = True
            break
        except OSError:
            time.sleep(0.1)
    if not up:
        proc.kill()
        out["log"] = (proc.stdout.read() or "")[-1500:]
        out["results"].append({"request": "start", "error": "app did not listen on $PORT within 30 s "
                               "(it must read the PORT env var, default 8080)"})
        return
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for r in reqs:
        url = f"http://127.0.0.1:{port}{r.get('path', '/')}"
        data = r.get("body")
        req = urllib.request.Request(url, method=r.get("method", "GET"),
                                     data=data.encode() if isinstance(data, str) else None,
                                     headers={"content-type": "application/json"} if data else {})
        try:
            with opener.open(req, timeout=10) as resp:
                out["results"].append({"request": f"{req.method} {r.get('path', '/')}", "status": resp.status,
                                       "body": resp.read(400).decode(errors="replace")})
        except urllib.error.HTTPError as e:
            out["results"].append({"request": f"{req.method} {r.get('path', '/')}", "status": e.code,
                                   "body": e.read(400).decode(errors="replace")})
        except Exception as e:
            out["results"].append({"request": f"{req.method} {r.get('path', '/')}", "error": f"{type(e).__name__}: {e}"})
    proc.kill()
    try:
        out["log"] = (proc.communicate(timeout=3)[0] or "")[-1500:]
    except Exception:
        pass


if __name__ == "__main__":
    try:
        result = main(sys.argv[1])
    except Exception as e:  # never die silently: the caller parses this line
        result = {"status": "failed", "results": [{"request": "harness", "error": f"{type(e).__name__}: {e}"}]}
    print("GCA_RESULT:" + json.dumps(result), flush=True)
