"""Model backends behind one function. The agent loop always speaks Bedrock-Converse-shaped messages;
the Gemini backend converts to and from them."""
import logging
import time
import uuid
from . import aws, config

log = logging.getLogger(__name__)


def converse(system: str, messages: list, tools: list, model_id: str | None = None) -> dict:
    """One model step. Returns {"message": ..., "stop": ..., "usage": ..., "model": ...}."""
    if config.CLOUD == "gcp":
        return _gemini(system, messages, tools, model_id or config.MODEL_ID)
    return _bedrock(system, messages, tools, model_id)


# ------------------------------------------------------------------ AWS Bedrock
def _bedrock(system, messages, tools, model_id):
    from botocore.exceptions import ClientError
    rt = aws.client("bedrock-runtime")
    models = [model_id or config.MODEL_ID]
    if config.FALLBACK_MODEL_ID and config.FALLBACK_MODEL_ID not in models:
        models.append(config.FALLBACK_MODEL_ID)
    last = None
    for m in models:
        try:
            r = rt.converse(modelId=m, system=[{"text": system}], messages=messages,
                            toolConfig={"tools": tools},
                            inferenceConfig={"maxTokens": 4096, "temperature": 0.2})
            msg = r["output"]["message"]
            # Some open-weight models return reasoning blocks that Converse refuses
            # to accept back in history; keep only text and toolUse.
            msg["content"] = [b for b in msg["content"] if "text" in b or "toolUse" in b] or [{"text": "(no output)"}]
            return {"message": msg, "stop": r["stopReason"], "usage": r.get("usage", {}), "model": m}
        except ClientError as e:
            log.warning("model %s failed: %s", m, e)
            last = e
    raise last


# ------------------------------------------------------------------ GCP Vertex AI (Gemini)
_clients = {}


def _genai(location=None):
    location = location or config.GCP_REGION
    if location not in _clients:
        from google import genai
        kw = {"vertexai": True, "project": config.GCP_CONTROL_PROJECT, "location": location}
        if config.GCP_ACCESS_TOKEN:  # local runs only; Cloud Run uses its service account
            from google.oauth2.credentials import Credentials
            kw["credentials"] = Credentials(config.GCP_ACCESS_TOKEN)
        _clients[location] = genai.Client(**kw)
    return _clients[location]


def _to_gemini(messages):
    from google.genai import types
    names = {}  # toolUseId -> tool name, so results can be matched to calls
    for m in messages:
        for b in m["content"]:
            if "toolUse" in b:
                names[b["toolUse"]["toolUseId"]] = b["toolUse"]["name"]
    out = []
    for m in messages:
        parts = []
        for b in m["content"]:
            if "text" in b and b["text"]:
                parts.append(types.Part(text=b["text"]))
            elif "toolUse" in b:
                parts.append(types.Part(function_call=types.FunctionCall(name=b["toolUse"]["name"], args=b["toolUse"]["input"])))
            elif "toolResult" in b:
                tr = b["toolResult"]
                text = "".join(c.get("text", "") for c in tr["content"])
                parts.append(types.Part(function_response=types.FunctionResponse(
                    name=names.get(tr["toolUseId"], "tool"), response={"result": text})))
        if parts:
            out.append(types.Content(role="user" if m["role"] == "user" else "model", parts=parts))
    return out


def _gemini(system, messages, tools, model_id):
    from google.genai import types
    decls = [types.FunctionDeclaration(name=t["toolSpec"]["name"], description=t["toolSpec"]["description"],
                                       parameters_json_schema=t["toolSpec"]["inputSchema"]["json"]) for t in tools]
    cfg = types.GenerateContentConfig(system_instruction=system, tools=[types.Tool(function_declarations=decls)],
                                      temperature=0.2, max_output_tokens=8192,
                                      automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True))
    contents = _to_gemini(messages)
    r = None
    last = None
    # A fresh project has small quotas: retry with backoff, alternating the regional and the global endpoint.
    for attempt, location in enumerate([config.GCP_REGION, "global", config.GCP_REGION, "global", config.GCP_REGION, "global"]):
        try:
            r = _genai(location).models.generate_content(model=model_id, contents=contents, config=cfg)
            break
        except Exception as e:
            last = e
            if "429" not in str(e) and "RESOURCE_EXHAUSTED" not in str(e) and "503" not in str(e):
                raise
            log.warning("vertex %s %s attempt %d: %s", location, model_id, attempt + 1, str(e)[:120])
            time.sleep(min(4 * 2 ** (attempt // 2), 20))
    if r is None:
        raise last
    blocks = []
    cand = r.candidates[0] if r.candidates else None
    for p in (cand.content.parts if cand and cand.content and cand.content.parts else []):
        if p.function_call:
            blocks.append({"toolUse": {"toolUseId": uuid.uuid4().hex[:20], "name": p.function_call.name,
                                       "input": dict(p.function_call.args or {})}})
        elif p.text and not getattr(p, "thought", False):
            blocks.append({"text": p.text})
    u = r.usage_metadata
    return {"message": {"role": "assistant", "content": blocks or [{"text": "(no output)"}]},
            "stop": "tool_use" if any("toolUse" in b for b in blocks) else "end_turn",
            "usage": {"inputTokens": getattr(u, "prompt_token_count", 0), "outputTokens": getattr(u, "candidates_token_count", 0)},
            "model": model_id}
