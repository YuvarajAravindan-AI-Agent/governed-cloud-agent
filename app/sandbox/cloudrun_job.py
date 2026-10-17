"""Default sandbox on GCP: one execution of the gca-sandbox Cloud Run job. The job runs as a
service account with no roles, on a VPC with no internet route; files arrive base64-zipped in an env var."""
import base64
import io
import time
import zipfile
from .. import cloud, config
from . import parse

NAME = "Cloud Run job (no-permission SA, no internet)"
JOB = "gca-sandbox"
MAX_ENV = 30_000


def health():
    return ("online", "managed, always available") if config.GCP_CONTROL_PROJECT else ("offline", "not configured")


def run(files: dict) -> dict:
    from datetime import datetime, timedelta, timezone
    since = (datetime.now(timezone.utc) - timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for k, v in files.items():
            z.writestr(k, v)
    payload = base64.b64encode(buf.getvalue()).decode()
    if len(payload) > MAX_ENV:
        return {"status": "failed", "results": [{"request": "sandbox", "error": "app too large for the Cloud Run job sandbox"}]}
    s = cloud.gcp_session()
    base = f"https://run.googleapis.com/v2/projects/{config.GCP_CONTROL_PROJECT}/locations/{config.GCP_REGION}"
    r = s.post(f"{base}/jobs/{JOB}:run", json={"overrides": {
        "containerOverrides": [{"env": [{"name": "GCA_BUNDLE", "value": payload}]}], "timeout": "300s"}})
    r.raise_for_status()
    execution = r.json()["metadata"]["name"]          # projects/.../executions/<id>
    exec_id = execution.rsplit("/", 1)[1]
    deadline = time.time() + 330
    while time.time() < deadline:
        e = s.get(f"https://run.googleapis.com/v2/{execution}").json()
        if e.get("completionTime"):
            break
        time.sleep(3)
    flt = (f'resource.type="cloud_run_job" AND resource.labels.job_name="{JOB}" AND timestamp>="{since}" '
           f'AND labels."run.googleapis.com/execution_name"="{exec_id}" AND textPayload:"GCA_RESULT"')
    for _ in range(45):  # job logs can land a minute or more after the execution finishes
        token = None
        while True:  # the Logging API can return empty pages with a nextPageToken
            body = {"resourceNames": [f"projects/{config.GCP_CONTROL_PROJECT}"], "filter": flt, "pageSize": 50}
            if token:
                body["pageToken"] = token
            d = s.post("https://logging.googleapis.com/v2/entries:list", json=body).json()
            text = "\n".join(x.get("textPayload", "") for x in d.get("entries", []))
            if "GCA_RESULT:" in text:
                return parse(text)
            token = d.get("nextPageToken")
            if not token:
                break
        time.sleep(3)
    return parse("")
