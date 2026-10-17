"""Hourly reaper: destroys every deployment whose gca-expires time has passed.
Source of truth is the session metadata in S3; a tag sweep afterwards reports orphans."""
import json
import time
from datetime import datetime, timezone
from . import aws, config, storage, tf
from .session import Session

BUDGET_SECONDS = 700  # Lambda limit is 900 s


def _meta(sid: str) -> dict:
    raw = storage.read(f"sessions/{sid}/meta.json")
    return json.loads(raw) if raw else {}


def run(now: datetime | None = None) -> dict:
    now = now or datetime.now(timezone.utc)
    t0 = time.time()
    report = {"checked": 0, "reaped": [], "failed": [], "skipped_for_time": [], "orphans": []}
    for sid in storage.list_session_ids():
        m = _meta(sid)
        report["checked"] += 1
        if not (m.get("deployed") or m.get("needs_cleanup")):
            continue
        exp = datetime.strptime(m["variables"]["expires"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        if exp > now and not m.get("needs_cleanup"):
            continue
        if time.time() - t0 > BUDGET_SECONDS:
            report["skipped_for_time"].append(sid)
            continue
        s = Session(sid)
        res = tf.destroy(s.ws, s.meta["variables"])
        s.audit("reaped", ok=res["ok"], expired=m["variables"]["expires"])
        if res["ok"]:
            s.meta.update(deployed=False, outputs={}, inventory=[], pending=None, needs_cleanup=False)
            s.save()
            report["reaped"].append(sid)
        else:
            report["failed"].append({"session": sid, "error": res["output"][-300:]})
        s.push()
    report["orphans"] = _orphans(now) if config.CLOUD == "aws" else []
    print(json.dumps({"reaper": report}))
    return report


def _orphans(now) -> list[str]:
    """Resources whose expiry passed but that no session accounts for (logged, never deleted)."""
    try:
        env = aws.executor_env()
        import boto3
        c = boto3.client("resourcegroupstaggingapi", region_name=config.REGION, aws_access_key_id=env["AWS_ACCESS_KEY_ID"],
                         aws_secret_access_key=env["AWS_SECRET_ACCESS_KEY"], aws_session_token=env.get("AWS_SESSION_TOKEN"))
        out = []
        for page in c.get_paginator("get_resources").paginate(TagFilters=[{"Key": "managed-by", "Values": ["governed-cloud-agent"]}]):
            for r in page["ResourceTagMappingList"]:
                t = {x["Key"]: x["Value"] for x in r["Tags"]}
                if t.get("gca-expires") and datetime.strptime(t["gca-expires"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) < now:
                    out.append(r["ResourceARN"])
        return out
    except Exception as e:
        return [f"orphan scan failed: {type(e).__name__}"]
