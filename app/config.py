"""Runtime configuration. Everything comes from env vars so the same code runs
locally (MODE=local) and inside AWS Lambda (MODE=cloud)."""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

CLOUD = os.getenv("GCA_CLOUD", "aws")                       # aws | gcp
MODE = os.getenv("GCA_MODE", "local")                      # local | cloud
REGION = os.getenv("GCA_REGION", "us-east-1")
AWS_PROFILE = os.getenv("GCA_AWS_PROFILE") or None         # local only; Lambda uses its role

# Model: any Bedrock Converse model with tool use. Cheap open-weight models first.
MODEL_ID = os.getenv("GCA_MODEL_ID", "openai.gpt-oss-120b-1:0" if CLOUD == "aws" else "gemini-2.5-flash")
FALLBACK_MODEL_ID = os.getenv("GCA_FALLBACK_MODEL_ID", "qwen.qwen3-coder-30b-a3b-v1:0" if CLOUD == "aws" else "")
MAX_STEPS = int(os.getenv("GCA_MAX_STEPS", "24"))

# Workspaces: one directory per chat session. In cloud mode they are synced to S3
# because Lambda's /tmp does not survive between invocations.
WORK_ROOT = Path(os.getenv("GCA_WORK_ROOT", "/tmp/gca-work" if MODE == "cloud" else str(ROOT / ".work")))
WORKSPACE_BUCKET = os.getenv("GCA_WORKSPACE_BUCKET", "")
STATE_BUCKET = os.getenv("GCA_STATE_BUCKET", "")

# Terraform runs as this role, never as the agent's own identity.
EXECUTOR_ROLE_ARN = os.getenv("GCA_EXECUTOR_ROLE_ARN", "")
BOUNDARY_ARN = os.getenv("GCA_BOUNDARY_ARN", "")
ACCOUNT_ID = os.getenv("GCA_ACCOUNT_ID", "")

TERRAFORM = os.getenv("GCA_TERRAFORM", "terraform")
OPA = os.getenv("GCA_OPA", "opa")
POLICY_DIR = ROOT / "policies" / CLOUD
TEMPLATE_DIR = ROOT / "templates" / CLOUD

# GCP
GCP_PROJECT = os.getenv("GCA_GCP_PROJECT", "")                 # workloads project: where deployed apps live
GCP_CONTROL_PROJECT = os.getenv("GCA_GCP_CONTROL_PROJECT", os.getenv("GCA_GCP_PROJECT", ""))  # chat app, state bucket, Vertex AI
GCP_REGION = os.getenv("GCA_GCP_REGION", "us-central1")
GCP_EXECUTOR_SA = os.getenv("GCA_GCP_EXECUTOR_SA", "")      # service account Terraform impersonates
GCP_ACCESS_TOKEN = os.getenv("GCA_GCP_ACCESS_TOKEN", "")    # local runs only

# Moyai sandbox relay (Netcup)
MOYAI_RELAY_URL = os.getenv("GCA_MOYAI_RELAY_URL", "")
MOYAI_RELAY_TOKEN = os.getenv("GCA_MOYAI_RELAY_TOKEN", "")

ACCESS_KEY = os.getenv("GCA_ACCESS_KEY", "")               # required in cloud mode
DEFAULT_TTL_HOURS = int(os.getenv("GCA_DEFAULT_TTL_HOURS", "24"))
