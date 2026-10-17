"""The agent loop. Yields UI events; persists history in the session."""
import json
from . import config, llm, tf, tools
from .session import Session

SYSTEM = """You are a cloud engineer agent inside a governed platform on {CLOUDNAME}. The user chats with you; you build, deploy and run what they ask.

How you work:
1. Pick the template that fits the request and call init_workspace (the tool description lists the templates). {PICK}
2. Write the application with write_file. You can only write inside the template's writable paths; the Terraform in main.tf is platform-managed and already correct.
3. Use test_code to run the app in an isolated sandbox with real HTTP requests for the important routes; fix failures before deploying. needs_cloud is acceptable (the sandbox has no cloud credentials by design).
4. Call propose_deploy. A policy gate checks the Terraform plan. If it blocks, read the violations, fix, and propose again. When it passes, a HUMAN approves; you never apply anything yourself.
5. After approval you are told the URL. Use check_url to verify (Fargate and CloudFront can take a minute; check_url retries), then reply with the URL and a short usage summary. The platform already lists the cloud services created; do not repeat that list.
When the user asks to delete, remove, destroy or tear down what you deployed, call destroy_deployment immediately; it needs no approval. Deployments auto-delete after 24 hours; if the user asks to keep it longer, call extend_lifetime with the hours (convert days; max 168).

If asked what you can build or which AWS services you can use, answer from the template list: say honestly that you create only what the templates define, and name the services in each. Be concise.
For HTML pages return content-type text/html. For JSON APIs return application/json. {EXTRA}"""


PICK = {"aws": "Prefer the cheapest fit: static-site for pages, lambda-web-app for APIs, lambda-dynamodb-app when data must be stored, fargate-web-app only when the user needs a regular always-on server or pip packages.",
        "gcp": "Prefer the cheapest fit: cloudrun-static-site for pages, cloudrun-web-app for APIs and servers (it supports pip packages), cloudrun-firestore-app when data must be stored."}
EXTRA = {"aws": "Lambda Function URL events use event['rawPath'] and event['requestContext']['http']['method']. Servers (Fargate) must listen on int(os.environ.get('PORT', '8080')).",
         "gcp": "Cloud Run apps must listen on 0.0.0.0 at int(os.environ.get('PORT', '8080')) and use the standard library or packages from requirements.txt."}


def system_prompt() -> str:
    return (SYSTEM.replace("{CLOUDNAME}", {"aws": "AWS", "gcp": "Google Cloud"}[config.CLOUD])
            .replace("{PICK}", PICK[config.CLOUD]).replace("{EXTRA}", EXTRA[config.CLOUD]))


def _text(msg) -> str:
    return "".join(b.get("text", "") for b in msg["content"])


def step_loop(s: Session):
    """Run model/tool steps until the model stops, an approval is needed, or MAX_STEPS."""
    h = s.meta["history"]
    for _ in range(config.MAX_STEPS):
        r = llm.converse(system_prompt(), h, tools.bedrock_tools())
        msg = r["message"]
        h.append(msg)
        yield {"type": "usage", "model": r["model"], "usage": r["usage"]}
        if _text(msg).strip():
            yield {"type": "text", "text": _text(msg)}
        uses = [b["toolUse"] for b in msg["content"] if "toolUse" in b]
        if not uses:
            break
        results, approval = [], None
        for u in uses:
            yield {"type": "tool_call", "name": u["name"], "input": {k: (v if k != "content" else f"<{len(v)} chars>") for k, v in u["input"].items()}}
            out, ev = tools.run(s, u["name"], u["input"])
            yield {"type": "tool_result", "name": u["name"], "text": out[:1200]}
            for e in ([] if not ev else ev if isinstance(ev, list) else [ev]):
                yield e
                if e["type"] == "approval":
                    approval = e
            results.append({"toolResult": {"toolUseId": u["toolUseId"], "content": [{"text": out[:6000]}]}})
        h.append({"role": "user", "content": results})
        s.save()
        if approval:
            break
    s.save()
    yield {"type": "done"}


def chat(s: Session, text: str):
    s.meta["history"].append({"role": "user", "content": [{"text": text}]})
    s.audit("user", text=text[:500])
    yield from step_loop(s)


def decide(s: Session, approve: bool):
    p = s.meta.get("pending")
    if not p:
        yield {"type": "text", "text": "Nothing is waiting for approval."}
        yield {"type": "done"}
        return
    h = s.meta["history"]
    s.meta["pending"] = None
    if not approve:
        s.audit("rejected", kind=p["kind"])
        s.save()
        h.append({"role": "user", "content": [{"text": f"[system] The human REJECTED the {p['kind']}. Ask what they want changed."}]})
        yield from step_loop(s)
        return
    s.audit("approved", kind=p["kind"], digest=p.get("digest"))
    if p["kind"] == "apply":
        yield {"type": "status", "text": "Applying approved plan…"}
        res = tf.apply(s.ws)
        s.audit("applied", ok=res["ok"])
        if res["ok"]:
            s.meta["deployed"] = True
            s.meta["outputs"] = res["outputs"]
            note = f"[system] Deployment APPLIED. Outputs: {json.dumps(res['outputs'])}. Verify with check_url, then reply with the URL and a short usage summary. The platform has already shown the user the list of AWS services created; do not repeat it."
            inv = tf.inventory(s.ws)
            s.meta["inventory"] = inv
            yield {"type": "deployed", "outputs": res["outputs"]}
            yield {"type": "text", "text": tf.format_inventory(inv, config.MODEL_ID)}
        else:
            # A failed apply can leave half the resources behind: roll them back right away.
            yield {"type": "status", "text": "Apply failed - rolling back partial resources…"}
            rb = tf.destroy(s.ws, s.meta["variables"])
            s.audit("rollback", ok=rb["ok"])
            s.meta["needs_cleanup"] = not rb["ok"]  # the reaper retries these
            tail = "Partial resources were rolled back." if rb["ok"] else "Rollback also failed; the reaper will retry cleanup."
            note = (f"[system] Apply FAILED:\n{res['output']}\n{tail} Tell the user what failed and why. "
                    "If it is a permissions problem of the platform, say so plainly; do not silently switch to a different template.")
    else:
        yield {"type": "status", "text": "Destroying…"}
        removed = s.meta.get("inventory", [])
        res = tf.destroy(s.ws, s.meta["variables"])
        s.audit("destroyed", ok=res["ok"])
        if res["ok"]:
            s.meta["deployed"] = False
            s.meta["outputs"] = {}
            yield {"type": "destroyed"}
            if removed:
                yield {"type": "text", "text": f"**{'AWS' if config.CLOUD == 'aws' else 'Google Cloud'} resources removed**\n\n" + "\n".join(f"- {i['service']}: `{i['name']}`" for i in removed)}
        note = "[system] Resources destroyed." if res["ok"] else f"[system] Destroy FAILED:\n{res['output']}"
    s.save()
    h.append({"role": "user", "content": [{"text": note}]})
    yield from step_loop(s)
