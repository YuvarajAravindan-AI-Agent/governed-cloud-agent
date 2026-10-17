"""Platform runner for fargate-web-app: fetch the app bundle from S3, install requirements, run app/main.py on :8080."""
import os
import subprocess
import sys
import zipfile

import boto3

bucket, key = os.environ["BUNDLE_BUCKET"], os.environ.get("BUNDLE_KEY", "bundle.zip")
os.makedirs("/app", exist_ok=True)
boto3.client("s3").download_file(bucket, key, "/tmp/bundle.zip")
with zipfile.ZipFile("/tmp/bundle.zip") as z:
    z.extractall("/app")
os.chdir("/app")
if os.path.exists("requirements.txt") and open("requirements.txt").read().strip():
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--no-cache-dir", "--target", "/app/.deps", "-r", "requirements.txt"])
    os.environ["PYTHONPATH"] = "/app/.deps"
os.environ.setdefault("PORT", "8080")
os.execv(sys.executable, [sys.executable, "main.py"])
