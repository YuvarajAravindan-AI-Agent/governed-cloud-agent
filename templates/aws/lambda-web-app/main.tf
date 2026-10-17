terraform {
  required_version = ">= 1.5"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
  }
}

variable "app_name" {
  type = string
}
variable "session_id" {
  type = string
}
variable "expires" {
  type = string # RFC3339 UTC; the reaper destroys after this
}
variable "boundary_arn" {
  type = string
}
variable "public" {
  type    = bool
  default = true
}

provider "aws" { region = "us-east-1" }

locals {
  name = "gca-${var.app_name}-${substr(var.session_id, 0, 6)}"
  tags = {
    "gca-session" = var.session_id
    "gca-expires" = var.expires
    "managed-by"  = "governed-cloud-agent"
    "exposure"    = var.public ? "public" : "private"
  }
}

data "archive_file" "code" {
  type        = "zip"
  source_dir  = "${path.module}/app"
  output_path = "${path.module}/app.zip"
}

resource "aws_iam_role" "fn" {
  name                 = local.name
  permissions_boundary = var.boundary_arn
  tags                 = local.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.fn.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "fn" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = 3
  tags              = local.tags
}

resource "aws_lambda_function" "app" {
  function_name    = local.name
  role             = aws_iam_role.fn.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = data.archive_file.code.output_path
  source_code_hash = data.archive_file.code.output_base64sha256
  memory_size      = 256
  timeout          = 10
  tags             = local.tags
  depends_on       = [aws_cloudwatch_log_group.fn, aws_iam_role_policy_attachment.logs]
}

resource "aws_lambda_function_url" "app" {
  function_name      = aws_lambda_function.app.function_name
  authorization_type = var.public ? "NONE" : "AWS_IAM"
}

resource "aws_lambda_permission" "public_url" {
  count                  = var.public ? 1 : 0
  statement_id           = "FunctionURLAllowPublicAccess"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.app.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "public_invoke" {
  count         = var.public ? 1 : 0
  statement_id  = "FunctionURLAllowInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app.function_name
  principal     = "*"
}

output "url" {
  value = aws_lambda_function_url.app.function_url
}
output "function" {
  value = aws_lambda_function.app.function_name
}
