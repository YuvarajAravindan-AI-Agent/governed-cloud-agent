"""Terraform + OPA plumbing. The agent never calls these directly with raw shell:
it can only request plan/apply/destroy through the tools below."""
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path
from . import cloud, config

TF_ENV_BASE = {"TF_IN_AUTOMATION": "1", "TF_INPUT": "0", "TF_CLI_ARGS": "-no-color",
               "TF_PLUGIN_CACHE_DIR": os.path.expanduser("~/.terraform.d/plugin-cache")}


def _run(cmd: list[str], cwd: Path, env_extra: dict, timeout: int = 600) -> tuple[int, str]:
    env = {**os.environ, **TF_ENV_BASE, **env_extra}
    os.makedirs(TF_ENV_BASE["TF_PLUGIN_CACHE_DIR"], exist_ok=True)
    p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    out = (p.stdout + p.stderr).strip()
    return p.returncode, out[-6000:]


def _backend_args(ws: Path, session_id: str) -> list[str]:
    return []  # local state inside the workspace; the workspace itself is synced to S3 in cloud mode


def init(ws: Path) -> tuple[int, str]:
    return _run([config.TERRAFORM, "init", "-input=false"], ws, cloud.executor_env())


def plan(ws: Path, variables: dict) -> dict:
    """terraform plan + OPA. Returns a structured result the UI can render."""
    env = cloud.executor_env()
    rc, out = init(ws)
    if rc:
        return {"ok": False, "stage": "init", "output": out}
    args = [config.TERRAFORM, "plan", "-input=false", "-out=plan.tfplan", "-detailed-exitcode"]
    for k, v in variables.items():
        args += ["-var", f"{k}={json.dumps(v) if isinstance(v, bool) else v}"]
    rc, out = _run(args, ws, env)
    if rc == 1:
        return {"ok": False, "stage": "plan", "output": out}
    rc2, js = _run([config.TERRAFORM, "show", "-json", "plan.tfplan"], ws, env)
    if rc2:
        return {"ok": False, "stage": "show", "output": js}
    # `show -json` output must not be truncated for OPA
    full = subprocess.run([config.TERRAFORM, "show", "-json", "plan.tfplan"], cwd=ws,
                          env={**os.environ, **TF_ENV_BASE, **env}, capture_output=True, text=True).stdout
    (ws / "plan.json").write_text(full)
    violations = policy_check(ws / "plan.json")
    plan_json = json.loads(full)
    changes = [{"address": c["address"], "actions": c["change"]["actions"]}
               for c in plan_json.get("resource_changes", []) if c["change"]["actions"] not in (["no-op"], ["read"])]
    digest = hashlib.sha256((ws / "plan.tfplan").read_bytes()).hexdigest()[:16]
    return {"ok": True, "changes": changes, "violations": violations, "plan_digest": digest,
            "has_changes": rc == 2, "summary": _summary(out)}


def _summary(out: str) -> str:
    for line in out.splitlines()[::-1]:
        if line.startswith("Plan:") or line.startswith("No changes"):
            return line
    return ""


def policy_check(plan_json: Path) -> list[str]:
    p = subprocess.run([config.OPA, "eval", "-f", "json", "-i", str(plan_json), "-d", str(config.POLICY_DIR),
                        "data.gca.deny"], capture_output=True, text=True)
    if p.returncode:
        return [f"policy engine error: {p.stderr.strip()[:300]}"]
    res = json.loads(p.stdout)["result"][0]["expressions"][0]["value"]
    return sorted(res)


def apply(ws: Path) -> dict:
    """Apply EXACTLY the saved plan file that the human reviewed."""
    env = cloud.executor_env()
    init(ws)  # workspaces are re-hydrated from S3 in cloud mode; .terraform is not synced
    rc, out = _run([config.TERRAFORM, "apply", "-input=false", "plan.tfplan"], ws, env, timeout=900)
    outputs = {}
    if rc == 0:
        _, o = _run([config.TERRAFORM, "output", "-json"], ws, env)
        try:
            outputs = {k: v["value"] for k, v in json.loads(o).items()}
        except Exception:
            pass
    return {"ok": rc == 0, "output": out[-2500:], "outputs": outputs}


def destroy(ws: Path, variables: dict) -> dict:
    env = cloud.executor_env()
    init(ws)
    args = [config.TERRAFORM, "destroy", "-auto-approve", "-input=false"]
    for k, v in variables.items():
        args += ["-var", f"{k}={json.dumps(v) if isinstance(v, bool) else v}"]
    rc, out = _run(args, ws, env, timeout=900)
    return {"ok": rc == 0, "output": out[-2500:]}


SERVICE_NAMES = {
    "aws_lambda_function": "AWS Lambda (function)",
    "aws_lambda_function_url": "AWS Lambda (public HTTPS Function URL)",
    "aws_lambda_permission": "AWS Lambda (resource policy)",
    "aws_iam_role": "AWS IAM (execution role, permissions boundary attached)",
    "aws_iam_role_policy_attachment": "AWS IAM (managed policy attachment)",
    "aws_iam_role_policy": "AWS IAM (inline policy)",
    "aws_cloudwatch_log_group": "Amazon CloudWatch Logs (log group)",
    "aws_dynamodb_table": "Amazon DynamoDB (table)",
    "aws_s3_bucket": "Amazon S3 (bucket)",
    "aws_sqs_queue": "Amazon SQS (queue)",
    "aws_sns_topic": "Amazon SNS (topic)",
    "aws_cloudwatch_event_rule": "Amazon EventBridge (rule)",
    "aws_apigatewayv2_api": "Amazon API Gateway (HTTP API)",
    "aws_s3_object": "Amazon S3 (object)",
    "aws_s3_bucket_policy": "Amazon S3 (bucket policy)",
    "aws_s3_bucket_public_access_block": "Amazon S3 (public access block)",
    "aws_cloudfront_distribution": "Amazon CloudFront (distribution)",
    "aws_cloudfront_origin_access_control": "Amazon CloudFront (origin access control)",
    "aws_ecs_cluster": "Amazon ECS (cluster)",
    "aws_ecs_task_definition": "Amazon ECS (task definition, Fargate)",
    "aws_ecs_service": "Amazon ECS (service, Fargate)",
    "aws_lb": "Elastic Load Balancing (Application Load Balancer)",
    "aws_lb_target_group": "Elastic Load Balancing (target group)",
    "aws_lb_listener": "Elastic Load Balancing (listener)",
    "aws_security_group": "Amazon VPC (security group)",
    "google_cloud_run_v2_service": "Google Cloud Run (service)",
    "google_cloud_run_v2_service_iam_member": "Google Cloud Run (invoker access)",
    "google_service_account": "Google IAM (service account)",
    "google_storage_bucket": "Google Cloud Storage (bucket)",
    "google_storage_bucket_object": "Google Cloud Storage (object)",
    "google_storage_bucket_iam_member": "Google Cloud Storage (bucket access)",
    "google_firestore_database": "Google Firestore (database)",
}


def inventory(ws: Path) -> list[dict]:
    """What actually exists, read from Terraform state (not from the model's claims)."""
    rc, out = _run([config.TERRAFORM, "show", "-json"], ws, cloud.executor_env())
    full = subprocess.run([config.TERRAFORM, "show", "-json"], cwd=ws, env={**os.environ, **TF_ENV_BASE, **cloud.executor_env()},
                          capture_output=True, text=True).stdout
    try:
        res = json.loads(full)["values"]["root_module"].get("resources", [])
    except Exception:
        return []
    items = []
    for r in res:
        if r["type"] not in SERVICE_NAMES:
            continue
        v = r["values"]
        name = v.get("function_name") or v.get("account_id") or v.get("name") or v.get("family") or v.get("bucket") or v.get("key") or v.get("id") or ""
        items.append({"service": SERVICE_NAMES[r["type"]], "type": r["type"], "name": name,
                      "arn": v.get("arn") or v.get("function_url") or ""})
    return items


def format_inventory(items: list[dict], model: str) -> str:
    lines = [f"**{'AWS' if config.CLOUD == 'aws' else 'Google Cloud'} services created for this task**", ""]
    seen: dict[tuple, int] = {}
    for i in items:
        seen[(i["service"], i["name"], i["arn"] if i["arn"].startswith("http") else "")] = seen.get((i["service"], i["name"], i["arn"] if i["arn"].startswith("http") else ""), 0) + 1
    for (svc, name, url), n in seen.items():
        lines.append(f"- {svc}: `{name}`" + (f" x{n}" if n > 1 else "") + (f" ({url})" if url else ""))
    used = ("Amazon Bedrock (model `%s`), AWS STS (role assumption), Amazon S3 (platform state bucket)." if config.CLOUD == "aws"
            else "Vertex AI (model `%s`), IAM service-account impersonation, Cloud Storage (platform state bucket).") % model
    lines += ["", "Used but not created: " + used]
    return "\n".join(lines)
