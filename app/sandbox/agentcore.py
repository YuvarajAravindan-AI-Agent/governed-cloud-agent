"""Default sandbox on AWS: AgentCore Code Interpreter. Isolated microVM session, no internet,
no AWS credentials inside (verified 2026-10-13)."""
import json
from .. import aws
from . import parse

NAME = "AgentCore Code Interpreter"
IDENT = "aws.codeinterpreter.v1"
WORKDIR = "gca"


def health():
    return "online", "managed, always available"


def _call(c, sid, name, args):
    r = c.invoke_code_interpreter(codeInterpreterIdentifier=IDENT, sessionId=sid, name=name, arguments=args)
    out = []
    for ev in r["stream"]:
        if "result" in ev:
            for x in ev["result"].get("content", []):
                out.append(x.get("text", ""))
    return "\n".join(out)


def run(files: dict) -> dict:
    c = aws.client("bedrock-agentcore")
    sid = c.start_code_interpreter_session(codeInterpreterIdentifier=IDENT, name="gca-test",
                                           sessionTimeoutSeconds=300)["sessionId"]
    try:
        _call(c, sid, "writeFiles", {"content": [{"path": f"{WORKDIR}/{k}", "text": v} for k, v in files.items()]})
        code = ("import subprocess, sys\n"
                f"p = subprocess.run([sys.executable, '{WORKDIR}/harness.py', '{WORKDIR}'], capture_output=True, text=True, timeout=240)\n"
                "print(p.stdout[-20000:]); print(p.stderr[-2000:])")
        return parse(_call(c, sid, "executeCode", {"language": "python", "code": code}))
    finally:
        c.stop_code_interpreter_session(codeInterpreterIdentifier=IDENT, sessionId=sid)
