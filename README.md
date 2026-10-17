# governed-cloud-agent

Chat in a browser, and an agent builds and runs the app on **AWS** or **Google Cloud**, with guard rails that live
outside the model:

```
browser chat -> agent (Bedrock gpt-oss / Vertex Gemini, 9 fixed tools, no shell)
             -> test in an isolated sandbox (Default or Moyai, chosen automatically)
             -> terraform plan -> OPA policy gate -> human Approve -> apply as a narrow executor identity
             -> verify the URL, list the cloud services created
hourly reaper deletes expired apps; "delete it" in chat removes everything instantly.
```

| | AWS | Google Cloud |
|---|---|---|
| Chat app | container Lambda + streaming Function URL | Cloud Run |
| Model | Bedrock `gpt-oss-120b` (Qwen3-Coder fallback) | Vertex AI `gemini-2.5-flash` |
| Templates | lambda-web-app, lambda-dynamodb-app, fargate-web-app, static-site | cloudrun-web-app, cloudrun-firestore-app, cloudrun-static-site |
| Default sandbox | AgentCore Code Interpreter | Cloud Run job, no-permission SA, no egress |
| Isolation | permissions boundary + `gca-executor` role | separate workloads project + `gca-executor` SA |

Layout: `app/` agent + server + sandbox adapter, `templates/<cloud>/` the only things the agent can deploy,
`policies/<cloud>/` OPA rules (tests in `tests/`), `bootstrap/` and `bootstrap-gcp/` human-applied guard rails,
`deploy/` and `deploy-gcp/` host the chat app, `relay/` + `ops/moyai/` the optional Moyai sandbox.

Tests: `opa test policies/aws tests/aws && opa test policies/gcp tests/gcp && python tests/test_routing.py && python tests/test_relay.py`

Secrets never live in this repo: access keys, the relay token, Terraform state and `*.auto.tfvars` are git-ignored.
Account and project IDs do appear, so keep the repo private.
