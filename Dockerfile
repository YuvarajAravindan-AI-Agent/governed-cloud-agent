FROM python:3.13-slim
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.9.1 /lambda-adapter /opt/extensions/lambda-adapter
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates unzip curl && rm -rf /var/lib/apt/lists/*
COPY container/terraform container/opa /usr/local/bin/
# Bake the providers in so `terraform init` never downloads anything at runtime.
COPY container/mirror.tf /tmp/mirror/main.tf
RUN cd /tmp/mirror && terraform providers mirror /opt/tfmirror && rm -rf /tmp/mirror
COPY container/terraformrc /etc/terraformrc
ENV TF_CLI_CONFIG_FILE=/etc/terraformrc HOME=/tmp \
    GCA_MODE=cloud GCA_TERRAFORM=/usr/local/bin/terraform GCA_OPA=/usr/local/bin/opa \
    AWS_LWA_INVOKE_MODE=response_stream PORT=8080 PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /srv
RUN pip install --no-cache-dir boto3 fastapi uvicorn pydantic
COPY app app
COPY policies policies
COPY templates templates
CMD ["python", "-m", "uvicorn", "app.server:app", "--host", "0.0.0.0", "--port", "8080"]
