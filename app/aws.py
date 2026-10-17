"""Boto3 sessions: the agent's own identity, and the narrower executor role that
Terraform and other mutating tools run as."""
import functools
from . import config


@functools.cache
def session():
    import boto3
    return boto3.Session(profile_name=config.AWS_PROFILE, region_name=config.REGION)


def client(name: str):
    return session().client(name)


def executor_env() -> dict:
    """Short-lived credentials for the executor role, as env vars for a subprocess.
    Falls back to the caller's own credentials when no executor role is configured
    (first local run before bootstrap)."""
    if not config.EXECUTOR_ROLE_ARN:
        creds = session().get_credentials().get_frozen_credentials()
        env = {"AWS_ACCESS_KEY_ID": creds.access_key, "AWS_SECRET_ACCESS_KEY": creds.secret_key}
        if creds.token:
            env["AWS_SESSION_TOKEN"] = creds.token
    else:
        c = client("sts").assume_role(RoleArn=config.EXECUTOR_ROLE_ARN,
                                      RoleSessionName="gca-terraform", DurationSeconds=3600)["Credentials"]
        env = {"AWS_ACCESS_KEY_ID": c["AccessKeyId"], "AWS_SECRET_ACCESS_KEY": c["SecretAccessKey"],
               "AWS_SESSION_TOKEN": c["SessionToken"]}
    env["AWS_REGION"] = env["AWS_DEFAULT_REGION"] = config.REGION
    return env
