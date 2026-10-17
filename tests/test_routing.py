"""Routing rules for the sandbox adapter, with fake backends."""
import os, pathlib, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from app import sandbox, config


class Fake:
    def __init__(self, name, online=True, result=None): self.NAME, self.online, self.calls = name, online, 0; self.result = result or {"status": "passed", "results": [{"status": 200}]}
    def health(self): return ("online", "") if self.online else ("offline", "down")
    def run(self, files): self.calls += 1; return dict(self.result)


def setup(reqs, default=None, moyai=None):
    d, m = default or Fake("D"), moyai or Fake("M")
    sandbox.backends = lambda: {"default": d, "moyai": m}
    ws = pathlib.Path(tempfile.mkdtemp()); (ws / "app").mkdir(); (ws / "app" / "handler.py").write_text("x=1")
    if reqs is not None: (ws / "app" / "requirements.txt").write_text(reqs)
    return ws, {"kind": "lambda", "root": "app", "entry": "handler.py"}, d, m


def test_all():
    config.CLOUD = "aws"
    ws, t, d, m = setup(None);                        r = sandbox.run(ws, t, [], False); assert r["sandbox"] == "D" and d.calls == 1 and m.calls == 0, "1 normal"
    ws, t, d, m = setup("flask\nrequests>=2\n");      r = sandbox.run(ws, t, [], False); assert d.calls == 1 and m.calls == 0, "preinstalled -> Default"
    ws, t, d, m = setup("pandas\n");                  r = sandbox.run(ws, t, [], False); assert r["sandbox"] == "M" and "pandas" in r["reason"] and d.calls == 0, "2 packages -> Moyai"
    ws, t, d, m = setup("pandas\n", moyai=Fake("M", online=False)); r = sandbox.run(ws, t, [], False); assert r["sandbox"] == "D" and "offline" in r["reason"] and d.calls == 1, "2b Moyai offline -> Default + note"
    ws, t, d, m = setup(None, moyai=Fake("M", online=False)); r = sandbox.run(ws, t, [], True); assert r["status"] == "unavailable" and d.calls == 0, "4 forced + offline -> refuse, no downgrade"
    ws, t, d, m = setup(None);                        r = sandbox.run(ws, t, [], True); assert r["sandbox"] == "M" and r["routed"] == "forced" and d.calls == 0, "4 forced + online"
    ws, t, d, m = setup(None, default=Fake("D", result={"status": "missing_packages", "results": []})); r = sandbox.run(ws, t, [], False); assert r["sandbox"] == "M" and "retried" in r["reason"], "safety-net retry"
    print("routing OK (7 cases)")


if __name__ == "__main__":
    test_all()
