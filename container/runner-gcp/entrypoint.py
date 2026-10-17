"""Platform runner for Cloud Run apps: fetch the app bundle from GCS, install requirements, run main.py on :8080."""
import os
import subprocess
import sys
import zipfile

from google.cloud import storage

bucket, key = os.environ["BUNDLE_BUCKET"], os.environ.get("BUNDLE_KEY", "bundle.zip")
os.makedirs("/tmp/app", exist_ok=True)
storage.Client().bucket(bucket).blob(key).download_to_filename("/tmp/bundle.zip")
with zipfile.ZipFile("/tmp/bundle.zip") as z:
    z.extractall("/tmp/app")
os.chdir("/tmp/app")
if os.path.exists("requirements.txt") and open("requirements.txt").read().strip():
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--no-cache-dir", "--target", "/tmp/deps", "-r", "requirements.txt"])
    os.environ["PYTHONPATH"] = "/tmp/deps"
os.environ["PORT"] = os.environ.get("PORT", "8080")
os.execv(sys.executable, [sys.executable, "main.py"])
