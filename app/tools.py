"""The only capabilities the model has. Note what is absent: no shell, no
raw cloud CLI, and no 'apply' — a human approves, the server applies."""
import time
import urllib.request
from . import config, tf
from .session import Session

SPEC = [
    {"name": "init_workspace", "description": "Start a new project from a template. Call this first. Templates: lambda-web-app (a Python AWS Lambda web app/API behind a public HTTPS URL).",
     "schema": {"type": "object", "properties": {"template": {"type": "string"}, "app_name": {"type": "string", "description": "lowercase, dashes ok, 2-21 chars"}, "public": {"type": "boolean", "description": "public URL or IAM-protected; default true"}}, "required": ["template", "app_name"]}},
    {"name": "list_files", "description": "List files in the workspace.", "schema": {"type": "object", "properties": {}}},
    {"name": "read_file", "description": "Read a workspace file.", "schema": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}},
    {"name": "write_file", "description": "Create or overwrite a workspace file. Only the template's writable paths accept writes (main.tf is platform-managed; read it if curious). Lambda templates: edit app/handler.py (handler.handler(event, context), Function URL event format; return {statusCode, headers, body}; stdlib + boto3 only). Fargate template: edit app/main.py listening on 0.0.0.0:8080 (+ optional app/requirements.txt). Static site: files under site/, entry site/index.html.",
     "schema": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]}},
    {"name": "test_code", "description": "Run the app in an isolated sandbox (never in the platform itself) and send it HTTP requests. Works for every template: Lambda handlers are invoked with Function URL events, servers are started on $PORT, static sites are served. Use before proposing a deploy. Status needs_cloud means the code needs real cloud services/credentials that the sandbox deliberately does not have; that is not a code bug.",
     "schema": {"type": "object", "properties": {"requests": {"type": "array", "description": "HTTP requests to send; default [GET /]",
                "items": {"type": "object", "properties": {"method": {"type": "string"}, "path": {"type": "string"}, "body": {"type": "string"}}, "required": ["path"]}}}}},
    {"name": "propose_deploy", "description": "Run terraform plan and the policy gate. If the policy gate reports violations, fix them and call again. If the plan is clean, the human is asked to approve; the turn then ends and you will be told the outcome.",
     "schema": {"type": "object", "properties": {"reason": {"type": "string", "description": "one sentence for the approver"}}}},
    {"name": "destroy_deployment", "description": "Immediately delete everything this session deployed. Call it as soon as the user asks to delete, remove, destroy or tear down the app. No confirmation is needed.",
     "schema": {"type": "object", "properties": {}}},
    {"name": "extend_lifetime", "description": "Keep the deployment longer before it auto-deletes. Call when the user asks to keep it longer / extend it. hours is added to the current expiry (max total lifetime 7 days from now). No approval needed; it only updates tags.",
     "schema": {"type": "object", "properties": {"hours": {"type": "integer", "description": "1-168"}}, "required": ["hours"]}},
    {"name": "check_url", "description": "HTTP GET a path on this session's deployed app (pass a path like /health, not a full URL) to verify it runs.",
     "schema": {"type": "object", "properties": {"path": {"type": "string"}}}},
]


def _spec() -> list:
    from .session import templates
    desc = "Start a new project from a template. Call this first. Pick the template that fits: " + " ".join(
        f"[{n}] {t['description']} (writable: {', '.join(t['writable'])})" for n, t in templates().items())
    out = []
    for t in SPEC:
        t = dict(t)
        if t["name"] == "init_workspace":
            t["description"] = desc
            t["schema"] = {"type": "object", "properties": {"template": {"type": "string", "enum": list(templates())},
                           "app_name": {"type": "string", "description": "lowercase, dashes ok, 2-21 chars"},
                           "public": {"type": "boolean", "description": "lambda templates only: public URL or IAM-protected; default true"}},
                           "required": ["template", "app_name"]}
        out.append(t)
    return out


def bedrock_tools() -> list:
    return [{"toolSpec": {"name": t["name"], "description": t["description"], "inputSchema": {"json": t["schema"]}}} for t in _spec()]


def run(s: Session, name: str, args: dict) -> tuple[str, dict | None]:
    """Returns (text for the model, optional event for the UI). Event type 'approval' ends the turn."""
    s.audit("tool", name=name, args={k: (v if k != "content" else f"<{len(v)} chars>") for k, v in args.items()})
    try:
        return _run(s, name, args)
    except Exception as e:  # tool errors go back to the model, not the user
        return f"tool error: {type(e).__name__}: {e}", None


def _need_ws(s):
    return None if s.meta["template"] else "no workspace yet; call init_workspace first"


def _run(s, name, a):
    if name == "init_workspace":
        return s.init_from_template(a.get("template", ""), a.get("app_name", ""), a.get("public", True)), {"type": "files", "files": s.files()}
    if err := (_need_ws(s) if name != "init_workspace" else None):
        return err, None
    if name == "list_files":
        return "\n".join(s.files()), None
    if name == "read_file":
        p = s.resolve(a.get("path", ""))
        return (p.read_text()[:8000] if p and p.is_file() else "no such file"), None
    if name == "write_file":
        p = s.resolve(a.get("path", ""))
        if not p:
            return "invalid path", None
        if not any(a["path"].startswith(w) for w in s.meta.get("writable", ["app/"])):
            return f"infrastructure files are managed by the platform template and are read-only. Writable paths for this template: {s.meta.get('writable')}", None
        if len(a.get("content", "")) > 60_000:
            return "file too large", None
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(a["content"])
        s.meta["pending"] = None  # any edit invalidates a pending approval
        s.save()
        return f"wrote {a['path']} ({len(a['content'])} chars)", {"type": "files", "files": s.files(), "changed": a["path"]}
    if name == "test_code":
        return _test_in_sandbox(s, a)
    if name == "propose_deploy":
        return _propose(s, a)
    if name == "extend_lifetime":
        return _extend(s, a)
    if name == "destroy_deployment":
        return _destroy_now(s)
    if name == "check_url":
        base = s.meta["outputs"].get("url")
        if not base:
            return "nothing deployed yet", None
        path = a.get("path", "")
        if path.startswith(base.rstrip("/")):  # models sometimes pass the full URL
            path = path[len(base.rstrip("/")):]
        if path.startswith("http"):
            return "check_url only accepts paths on this session's deployed URL", None
        url = base.rstrip("/") + "/" + path.lstrip("/")
        t = time.time()
        last = ""
        for attempt in range(10):  # load balancers and new containers need a minute to come up
            try:
                with urllib.request.urlopen(url, timeout=15) as r:
                    return f"HTTP {r.status} in {time.time()-t:.1f}s\n{r.read(1500).decode(errors='replace')}", None
            except Exception as e:
                code = getattr(e, "code", None)
                body = e.read(800).decode(errors="replace") if hasattr(e, "read") else ""
                last = f"request failed: {code or type(e).__name__} {body}"
                if code is not None and code not in (502, 503, 504):
                    return last, None
                time.sleep(12)
        return last + " (retried for ~2 minutes)", None
    return f"unknown tool {name}", None


def _test_in_sandbox(s, a):
    import json
    from . import sandbox
    test = s.meta.get("test")
    if not isinstance(test, dict):
        return "this workspace predates sandbox testing; call init_workspace again", None
    reqs = a.get("requests") or [{"method": "GET", "path": "/"}]
    res = sandbox.run(s.ws, test, reqs[:10], force_moyai=bool(s.meta.get("force_moyai")))
    s.audit("sandbox_test", sandbox=res.get("sandbox"), status=res.get("status"), seconds=res.get("seconds"),
            routed=res.get("routed"), reason=res.get("reason"))
    ev = {"type": "sandbox", "sandbox": res.get("sandbox"), "status": res["status"], "seconds": res.get("seconds"),
          "reason": res.get("reason"), "detail": res.get("detail")}
    if res["status"] == "unavailable":
        return (f"The sandbox required for this session ({res['sandbox']}) is offline: {res.get('detail')}. Do NOT deploy untested; "
                "tell the user to start the Moyai cluster or turn off Force Moyai."), ev
    text = json.dumps({k: res.get(k) for k in ("sandbox", "reason", "status", "seconds", "syntax", "install", "results", "log") if res.get(k)}, indent=1)
    return text[:5000], ev


def _propose(s, a):
    v = s.meta["variables"]
    res = tf.plan(s.ws, v)
    s.audit("plan", ok=res.get("ok"), violations=res.get("violations"), digest=res.get("plan_digest"))
    if not res["ok"]:
        return f"terraform {res['stage']} failed:\n{res['output']}", None
    if res["violations"]:
        return "POLICY GATE BLOCKED the plan. Fix these and call propose_deploy again:\n- " + "\n- ".join(res["violations"]), \
            {"type": "policy_block", "violations": res["violations"]}
    if not res["has_changes"]:
        return "No infrastructure changes needed (code is unchanged).", None
    s.meta["pending"] = {"kind": "apply", "digest": res["plan_digest"], "reason": a.get("reason", ""), "changes": res["changes"]}
    s.save()
    s.audit("approval_requested", kind="apply", digest=res["plan_digest"])
    return "Policy gate passed. Waiting for human approval.", {"type": "approval", "kind": "apply", "reason": a.get("reason", ""),
            "changes": res["changes"], "violations": [], "digest": res["plan_digest"], "summary": res["summary"]}


def _destroy_now(s):
    if not (s.meta["deployed"] or s.meta.get("needs_cleanup")):
        return "nothing is deployed in this session", None
    removed = s.meta.get("inventory", [])
    res = tf.destroy(s.ws, s.meta["variables"])
    s.audit("destroyed", ok=res["ok"], by="user-chat")
    if not res["ok"]:
        return f"destroy FAILED:\n{res['output']}", None
    s.meta.update(deployed=False, outputs={}, inventory=[], pending=None, needs_cleanup=False)
    s.save()
    lines = "\n".join(f"- {i['service']}: `{i['name']}`" for i in removed)
    return "Destroyed. All resources of this session are gone.", [
        {"type": "destroyed"},
        {"type": "text", "text": f"**{'AWS' if config.CLOUD == 'aws' else 'Google Cloud'} resources removed**\n\n" + lines}]


def _extend(s, a):
    from datetime import datetime, timedelta, timezone
    if not s.meta["deployed"]:
        return "nothing is deployed in this session", None
    try:
        hours = int(a.get("hours"))
    except (TypeError, ValueError):
        return "hours must be an integer", None
    if not 1 <= hours <= 168:
        return "hours must be between 1 and 168", None
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    now = datetime.now(timezone.utc)
    old = s.meta["variables"]["expires"]
    cur = datetime.strptime(old, fmt).replace(tzinfo=timezone.utc)
    new = min(max(cur, now) + timedelta(hours=hours), now + timedelta(hours=168))
    s.meta["variables"]["expires"] = new.strftime(fmt)
    res = tf.plan(s.ws, s.meta["variables"])
    risky = [c for c in res.get("changes", []) if c["actions"] != ["update"]]
    if not res["ok"] or res["violations"] or risky:
        s.meta["variables"]["expires"] = old
        s.save()
        why = res.get("output") or res.get("violations") or risky
        return f"could not extend: {why}", None
    ap = tf.apply(s.ws)
    if not ap["ok"]:
        s.meta["variables"]["expires"] = old
        s.save()
        return f"extend failed: {ap['output']}", None
    s.save()
    s.audit("extended", old=old, new=s.meta["variables"]["expires"], hours=hours)
    return f"Lifetime extended. New auto-delete time: {s.meta['variables']['expires']} UTC.", {"type": "text", "text": f"Kept for longer. It will now auto-delete at **{s.meta['variables']['expires']} UTC**."}
