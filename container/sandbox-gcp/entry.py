"""gca-sandbox Cloud Run job: unpack GCA_BUNDLE (base64 zip) and run the harness. No network, no permissions."""
import base64
import io
import os
import subprocess
import sys
import zipfile

work = "/tmp/w"
os.makedirs(work, exist_ok=True)
zipfile.ZipFile(io.BytesIO(base64.b64decode(os.environ["GCA_BUNDLE"]))).extractall(work)
p = subprocess.run([sys.executable, os.path.join(work, "harness.py"), work], capture_output=True, text=True, timeout=280)
# Cloud Logging splits long lines; keep the result line compact and print it last.
sys.stderr.write(p.stderr[-2000:])
print(p.stdout.strip().splitlines()[-1] if p.stdout.strip() else "GCA_RESULT:{\"status\":\"failed\"}", flush=True)
