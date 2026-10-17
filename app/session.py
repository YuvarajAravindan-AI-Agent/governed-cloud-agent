"""Per-chat-session workspace, variables, pending approval and audit log."""
import json
import re
import shutil
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
import os
from . import config, storage

SAFE = re.compile(r"^[a-zA-Z0-9_./-]+$")


class Session:
    def __init__(self, sid: str | None = None):
        self.id = sid or uuid.uuid4().hex[:12]
        self.dir = config.WORK_ROOT / self.id
        self.ws = self.dir / "ws"
        self.meta_path = self.dir / "meta.json"
        self.audit_path = self.dir / "audit.jsonl"
        if config.MODE == "cloud":
            self.pull()
        self.dir.mkdir(parents=True, exist_ok=True)
        self.meta = json.loads(self.meta_path.read_text()) if self.meta_path.exists() else {
            "template": None, "force_moyai": False, "variables": {}, "pending": None, "deployed": False, "outputs": {}, "history": []}

    def save(self):
        self.meta_path.write_text(json.dumps(self.meta, indent=1))

    def audit(self, event: str, **data):
        with self.audit_path.open("a") as f:
            f.write(json.dumps({"t": datetime.now(timezone.utc).isoformat(), "event": event, **data}) + "\n")

    def init_from_template(self, template: str, app_name: str, public: bool = True) -> str:
        src = config.TEMPLATE_DIR / template
        if not SAFE.match(template) or not (src / "template.json").is_file():
            return f"unknown template {template!r}; available: {sorted(templates())}"
        if not re.fullmatch(r"[a-z][a-z0-9-]{1,20}", app_name):
            return "app_name must be lowercase letters, digits, dashes (2-21 chars), starting with a letter"
        if self.ws.exists():
            shutil.rmtree(self.ws)
        shutil.copytree(src, self.ws, ignore=shutil.ignore_patterns(".terraform*", "*.zip", "*.tfplan", "plan.json", "README.md"))
        expires = (datetime.now(timezone.utc) + timedelta(hours=config.DEFAULT_TTL_HOURS)).strftime("%Y-%m-%dT%H:%M:%SZ")
        info = json.loads((src / "template.json").read_text())
        self.meta.update(template=template, writable=info["writable"], test=info["test"], pending=None, deployed=False, outputs={}, variables={
            "app_name": app_name, "session_id": self.id, "expires": expires, "public": public,
            **({"project_id": config.GCP_PROJECT, "region": config.GCP_REGION} if config.CLOUD == "gcp" else
               {"boundary_arn": config.BOUNDARY_ARN or "arn:aws:iam::000000000000:policy/gca-workload-boundary"})})
        self.save()
        self.audit("init", template=template, app_name=app_name)
        return f"workspace ready from template {template}. Files: {self.files()}"

    def files(self) -> list[str]:
        if not self.ws.exists():
            return []
        skip = ("template.json", "__pycache__", ".terraform", "plan.tfplan", "plan.json", "app.zip", "terraform.tfstate", ".terraform.lock.hcl")
        return sorted(str(p.relative_to(self.ws)) for p in self.ws.rglob("*")
                      if p.is_file() and not any(s in p.parts or p.name == s for s in skip) and not p.name.startswith("terraform.tfstate"))

    def resolve(self, rel: str) -> Path | None:
        if not SAFE.match(rel) or ".." in rel.split("/"):
            return None
        p = (self.ws / rel).resolve()
        return p if str(p).startswith(str(self.ws.resolve())) else None


def _prefix(sid): return f"sessions/{sid}/"


def _pull(self):
    """Cloud mode: the container disk is ephemeral, so rehydrate the session from object storage."""
    storage.pull(_prefix(self.id), self.dir)


def _push(self):
    if config.MODE == "cloud":
        storage.push(_prefix(self.id), self.dir)


Session.pull = _pull
Session.push = _push


def templates() -> dict:
    return {p.name: json.loads((p / "template.json").read_text())
            for p in sorted(config.TEMPLATE_DIR.iterdir()) if (p / "template.json").is_file()}
