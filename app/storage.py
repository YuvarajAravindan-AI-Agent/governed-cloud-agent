"""Session persistence: S3 on AWS, GCS on GCP. Same four operations."""
import os
import shutil
from pathlib import Path
from . import aws, config

SKIP_DIRS = (".terraform", "__pycache__")


def _gcs():
    from google.cloud import storage
    import google.auth
    from google.oauth2.credentials import Credentials
    if config.GCP_ACCESS_TOKEN:
        return storage.Client(project=config.GCP_CONTROL_PROJECT, credentials=Credentials(config.GCP_ACCESS_TOKEN))
    return storage.Client(project=config.GCP_CONTROL_PROJECT)


def list_session_ids() -> list[str]:
    if config.CLOUD == "gcp":
        it = _gcs().list_blobs(config.STATE_BUCKET, prefix="sessions/", delimiter="/")
        list(it)
        return [p.split("/")[1] for p in it.prefixes]
    s3 = aws.client("s3")
    out = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=config.STATE_BUCKET, Prefix="sessions/", Delimiter="/"):
        out += [p["Prefix"].split("/")[1] for p in page.get("CommonPrefixes", [])]
    return out


def read(key: str) -> bytes | None:
    try:
        if config.CLOUD == "gcp":
            b = _gcs().bucket(config.STATE_BUCKET).blob(key)
            return b.download_as_bytes() if b.exists() else None
        return aws.client("s3").get_object(Bucket=config.STATE_BUCKET, Key=key)["Body"].read()
    except Exception:
        return None


def pull(prefix: str, dest: Path):
    if dest.exists():
        shutil.rmtree(dest)
    if config.CLOUD == "gcp":
        for b in _gcs().list_blobs(config.STATE_BUCKET, prefix=prefix):
            if b.name.endswith("/"):
                continue
            f = dest / b.name[len(prefix):]
            f.parent.mkdir(parents=True, exist_ok=True)
            b.download_to_filename(str(f))
        return
    s3 = aws.client("s3")
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=config.STATE_BUCKET, Prefix=prefix):
        for o in page.get("Contents", []):
            f = dest / o["Key"][len(prefix):]
            f.parent.mkdir(parents=True, exist_ok=True)
            s3.download_file(config.STATE_BUCKET, o["Key"], str(f))


def push(prefix: str, src: Path):
    gcs = _gcs().bucket(config.STATE_BUCKET) if config.CLOUD == "gcp" else None
    s3 = None if gcs else aws.client("s3")
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            full = Path(root) / name
            key = prefix + str(full.relative_to(src))
            if gcs:
                gcs.blob(key).upload_from_filename(str(full))
            else:
                s3.upload_file(str(full), config.STATE_BUCKET, key)
    shutil.rmtree(src, ignore_errors=True)
