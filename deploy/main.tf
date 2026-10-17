# Hosts the chat application itself: ECR image -> container Lambda -> streaming Function URL.
terraform {
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "enterprises"
}

variable "moyai_relay_url" {
  type    = string
  default = "https://moyai.ai-agentic-enterprises.com/gca-relay"
}

variable "moyai_relay_token" {
  type      = string
  default   = ""
  sensitive = true
}

variable "image_tag" {
  type    = string
  default = ""
}

data "aws_caller_identity" "me" {}

locals {
  acct = data.aws_caller_identity.me.account_id
  tags = { "managed-by" = "gca-platform", "app" = "governed-cloud-agent" }
}

resource "aws_ecr_repository" "app" {
  name                 = "gca-agent-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  tags                 = local.tags
}

resource "random_password" "access" {
  length  = 32
  special = false
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/aws/lambda/gca-agent-app"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_lambda_function" "app" {
  count         = var.image_tag == "" ? 0 : 1
  function_name = "gca-agent-app"
  role          = "arn:aws:iam::${local.acct}:role/gca-agent-app"
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
  timeout       = 900
  memory_size   = 2048
  ephemeral_storage {
    size = 6144
  }
  environment {
    variables = {
      GCA_ACCESS_KEY        = random_password.access.result
      GCA_STATE_BUCKET      = "gca-state-${local.acct}"
      GCA_EXECUTOR_ROLE_ARN = "arn:aws:iam::${local.acct}:role/gca-executor"
      GCA_BOUNDARY_ARN      = "arn:aws:iam::${local.acct}:policy/gca-workload-boundary"
      GCA_ACCOUNT_ID        = local.acct
      GCA_MOYAI_RELAY_URL   = var.moyai_relay_url
      GCA_MOYAI_RELAY_TOKEN = var.moyai_relay_token
    }
  }
  tags       = local.tags
  depends_on = [aws_cloudwatch_log_group.app]
}

resource "aws_lambda_function_url" "app" {
  count              = var.image_tag == "" ? 0 : 1
  function_name      = aws_lambda_function.app[0].function_name
  authorization_type = "NONE"
  invoke_mode        = "RESPONSE_STREAM"
}

resource "aws_lambda_permission" "url" {
  count                  = var.image_tag == "" ? 0 : 1
  statement_id           = "FunctionURLAllowPublicAccess"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.app[0].function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "invoke" {
  count         = var.image_tag == "" ? 0 : 1
  statement_id  = "FunctionURLAllowInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app[0].function_name
  principal     = "*"
}

output "repo_url" {
  value = aws_ecr_repository.app.repository_url
}
output "chat_url" {
  value = var.image_tag == "" ? "" : aws_lambda_function_url.app[0].function_url
}
output "access_key" {
  value     = random_password.access.result
  sensitive = true
}

# ---- Reaper: hourly schedule that invokes the same function with a signed event ----
resource "aws_cloudwatch_event_rule" "reaper" {
  name                = "gca-reaper-hourly"
  schedule_expression = "rate(1 hour)"
  tags                = local.tags
}

resource "aws_cloudwatch_event_target" "reaper" {
  count = var.image_tag == "" ? 0 : 1
  rule  = aws_cloudwatch_event_rule.reaper.name
  arn   = aws_lambda_function.app[0].arn
  input = jsonencode({ gca_reaper_token = random_password.access.result })
}

resource "aws_lambda_permission" "reaper" {
  count         = var.image_tag == "" ? 0 : 1
  statement_id  = "AllowEventBridgeReaper"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.reaper.arn
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep the last 2 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 2 }
      action       = { type = "expire" }
    }]
  })
}
