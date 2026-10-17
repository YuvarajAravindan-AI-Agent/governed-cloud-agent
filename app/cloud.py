"""Provider-neutral entry points. Terraform and the model run with different identities per cloud."""
from . import aws, config


def executor_env() -> dict:
    """Environment for Terraform subprocesses: short-lived credentials for the narrow executor identity."""
    if config.CLOUD == "gcp":
        env = {"GOOGLE_PROJECT": config.GCP_PROJECT, "GOOGLE_REGION": config.GCP_REGION,
               "GOOGLE_USER_PROJECT_OVERRIDE": "true", "GOOGLE_BILLING_PROJECT": config.GCP_PROJECT}
        if config.GCP_EXECUTOR_SA:
            env["GOOGLE_IMPERSONATE_SERVICE_ACCOUNT"] = config.GCP_EXECUTOR_SA
        elif config.GCP_ACCESS_TOKEN:
            env["GOOGLE_OAUTH_ACCESS_TOKEN"] = config.GCP_ACCESS_TOKEN
        return env
    return aws.executor_env()


def gcp_session():
    """Authorized HTTP session as the chat app's own identity (local runs: the founder token)."""
    from google.auth.transport.requests import AuthorizedSession
    if config.GCP_ACCESS_TOKEN:
        from google.oauth2.credentials import Credentials
        return AuthorizedSession(Credentials(config.GCP_ACCESS_TOKEN))
    import google.auth
    creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    return AuthorizedSession(creds)
