import hmac
import json
import re
import shutil
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel
from . import agent, config
from .session import Session

app = FastAPI(title="governed-cloud-agent")
SID = re.compile(r"^[a-f0-9]{12}$")


def auth(key: str | None):
    if config.ACCESS_KEY and not hmac.compare_digest(key or "", config.ACCESS_KEY):
        raise HTTPException(401, "bad access key")
    if config.MODE == "cloud" and not config.ACCESS_KEY:
        raise HTTPException(500, "server has no access key configured")


def sse(gen, sess=None):
    def it():
        try:
            for ev in gen:
                yield f"data: {json.dumps(ev, default=str)}\n\n"
        except Exception as e:
            yield f"data: {json.dumps({'type': 'error', 'text': f'{type(e).__name__}: {e}'})}\n\n"
            yield f"data: {json.dumps({'type': 'done'})}\n\n"
        finally:
            if sess:
                sess.push()
    return StreamingResponse(it(), media_type="text/event-stream", headers={"cache-control": "no-store", "x-accel-buffering": "no"})


def load(sid: str) -> Session:
    if not SID.match(sid):
        raise HTTPException(400, "bad session id")
    return Session(sid)


class Chat(BaseModel):
    session: str
    text: str
    force_moyai: bool | None = None


class Decide(BaseModel):
    session: str
    approve: bool


@app.post("/api/chat")
def chat(b: Chat, x_access_key: str | None = Header(None)):
    auth(x_access_key)
    s = load(b.session)
    if b.force_moyai is not None and bool(s.meta.get("force_moyai")) != b.force_moyai:
        s.meta["force_moyai"] = b.force_moyai
        s.audit("force_moyai", value=b.force_moyai)
        s.save()
    return sse(agent.chat(s, b.text[:4000]), s)


@app.post("/api/decide")
def decide(b: Decide, x_access_key: str | None = Header(None)):
    auth(x_access_key)
    s = load(b.session)
    return sse(agent.decide(s, b.approve), s)


@app.get("/api/session/{sid}")
def get_session(sid: str, x_access_key: str | None = Header(None)):
    auth(x_access_key)
    s = load(sid)
    try:
        return {"id": s.id, "files": s.files(), "pending": s.meta["pending"], "deployed": s.meta["deployed"],
            "outputs": s.meta["outputs"], "expires": s.meta["variables"].get("expires")}
    finally:
        shutil.rmtree(s.dir, ignore_errors=True) if config.MODE == "cloud" else None


@app.get("/api/session/{sid}/audit")
def audit(sid: str, x_access_key: str | None = Header(None)):
    auth(x_access_key)
    s = load(sid)
    try:
        return [json.loads(l) for l in s.audit_path.read_text().splitlines()] if s.audit_path.exists() else []
    finally:
        shutil.rmtree(s.dir, ignore_errors=True) if config.MODE == "cloud" else None


@app.post("/events")
def events(body: dict):
    """EventBridge schedule (delivered by the Lambda Web Adapter as a pass-through event)."""
    if config.MODE != "cloud" or not config.ACCESS_KEY or not hmac.compare_digest(str(body.get("gca_reaper_token", "")), config.ACCESS_KEY):
        raise HTTPException(401, "not allowed")
    from . import reaper
    return reaper.run()


@app.get("/api/sandboxes")
def sandboxes(x_access_key: str | None = Header(None)):
    auth(x_access_key)
    from . import sandbox
    return sandbox.status()


@app.get("/api/config")
def cfg():
    return {"model": config.MODEL_ID, "mode": config.MODE, "needs_key": bool(config.ACCESS_KEY), "cloud": config.CLOUD}


@app.get("/")
def index():
    return FileResponse(config.ROOT / "app" / "static" / "index.html")
