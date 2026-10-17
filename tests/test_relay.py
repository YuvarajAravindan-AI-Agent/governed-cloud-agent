"""Relay logic against a fake Substrate: the 'sandbox' is a local temp dir, the harness is the real one."""
import asyncio
import importlib.util
import os
import subprocess
import sys
import tempfile
from types import SimpleNamespace

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
spec = importlib.util.spec_from_file_location("gca_relay", os.path.join(os.path.dirname(__file__), "..", "relay", "gca_relay.py"))
relay = importlib.util.module_from_spec(spec); spec.loader.exec_module(relay)


class Op:  # mimics Moyai's  obj.method.aio(...)
    def __init__(self, fn): self.aio = fn


class Proc:
    def __init__(self, out, err): self.stdout = SimpleNamespace(read=Op(self._r(out))); self.stderr = SimpleNamespace(read=Op(self._r(err))); self.wait = Op(self._r(0))
    @staticmethod
    def _r(v):
        async def f(): return v
        return f


class FakeSandbox:
    def __init__(self, root): self.root = root; self.terminated = False
    def _p(self, p): return os.path.join(self.root, p.lstrip("/"))
    async def _write(self, text, path):
        os.makedirs(os.path.dirname(self._p(path)), exist_ok=True); open(self._p(path), "w").write(text)
    async def _exec(self, *cmd, timeout=None, env=None):
        cmd = [self._p(c) if c.startswith("/tmp/") else c for c in cmd]
        p = subprocess.run(cmd if cmd[0] != "python3" else [sys.executable] + cmd[1:], capture_output=True, text=True, timeout=120)
        return Proc(p.stdout, p.stderr)
    async def _term(self): self.terminated = True
    @property
    def filesystem(self): return SimpleNamespace(write_text=Op(self._write))
    @property
    def exec(self): return Op(self._exec)
    @property
    def terminate(self): return Op(self._term)


class FakeProvider:
    def __init__(self): self.box = None; self.up = True
    async def create(self, **kw):
        self.box = FakeSandbox(tempfile.mkdtemp()); return self.box
    async def rpc(self, method, data, timeout=0):
        if not self.up: raise ConnectionError("down")
        return {}


def test_health_and_run():
    prov = FakeProvider()
    assert asyncio.run(relay.health(prov))["status"] == "online"
    prov.up = False
    h = asyncio.run(relay.health(prov)); assert h["status"] == "offline" and "moyai-up" in h["detail"]
    from app import sandbox
    import pathlib, json
    src = pathlib.Path("templates/aws/lambda-web-app")
    files = sandbox.bundle(src, json.loads((src / "template.json").read_text())["test"], [{"path": "/"}])
    relay.WORK = "/tmp/gca"
    res = asyncio.run(relay.run(files, prov))
    assert res["status"] == "passed" and res["results"][0]["status"] == 200, res
    assert prov.box.terminated, "sandbox must be destroyed after every run"
    print("relay OK:", res["status"], res["results"][0]["status"], "terminated:", prov.box.terminated)


if __name__ == "__main__":
    test_health_and_run()
