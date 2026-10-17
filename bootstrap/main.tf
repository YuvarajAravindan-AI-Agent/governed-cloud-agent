# One-time bootstrap: the guard rails the agent itself can never modify.
# Applied by a human (SSO admin), not by the agent.
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "enterprises"
}

data "aws_caller_identity" "me" {}
data "aws_region" "cur" {}

locals {
  acct = data.aws_caller_identity.me.account_id
  tags = { "managed-by" = "gca-bootstrap" }
}

# ---- State / workspace bucket (private) -------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = "gca-state-${local.acct}"
  tags   = local.tags
}
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# ---- Permissions boundary: the ceiling for every role the agent creates -----
data "aws_iam_policy_document" "boundary" {
  statement {
    sid    = "WorkloadServicesOnGcaNames"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream", "logs:PutLogEvents",
      "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:Scan",
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket",
      "sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes",
      "sns:Publish",
    ]
    resources = [
      "arn:aws:logs:*:${local.acct}:log-group:/aws/lambda/gca-*:*",
      "arn:aws:dynamodb:*:${local.acct}:table/gca-*",
      "arn:aws:s3:::gca-app-*", "arn:aws:s3:::gca-app-*/*",
      "arn:aws:sqs:*:${local.acct}:gca-*",
      "arn:aws:sns:*:${local.acct}:gca-*",
      "arn:aws:logs:*:${local.acct}:log-group:/ecs/gca-*:*",
    ]
  }
  statement {
    sid       = "RunnerImagePull"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = ["arn:aws:ecr:*:${local.acct}:repository/gca-runner"]
  }
  statement {
    sid       = "EcrAuthToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
}
resource "aws_iam_policy" "boundary" {
  name   = "gca-workload-boundary"
  policy = data.aws_iam_policy_document.boundary.json
  tags   = local.tags
}

# ---- Executor role: what Terraform runs as -----------------------------------
data "aws_iam_policy_document" "executor_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.acct}:root"]
    }
    # Only the SSO admin (local runs) and the agent's own Lambda role may assume it.
    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values = [
        "arn:aws:iam::${local.acct}:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_AdministratorAccess_*",
        "arn:aws:iam::${local.acct}:role/gca-agent-app",
      ]
    }
  }
}

data "aws_iam_policy_document" "executor" {
  statement {
    sid       = "LambdaOnGcaNames"
    actions   = ["lambda:*"]
    resources = ["arn:aws:lambda:*:${local.acct}:function:gca-*"]
  }
  statement {
    sid       = "LambdaList"
    actions   = ["lambda:ListFunctions", "lambda:ListTags", "lambda:GetAccountSettings"]
    resources = ["*"]
  }
  statement {
    sid       = "LogsOnGcaNames"
    actions   = ["logs:*"]
    resources = ["arn:aws:logs:*:${local.acct}:log-group:/aws/lambda/gca-*", "arn:aws:logs:*:${local.acct}:log-group:/aws/lambda/gca-*:*"]
  }
  statement {
    sid       = "LogsDescribe"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }
  statement {
    sid       = "DynamoOnGcaNames"
    actions   = ["dynamodb:*"]
    resources = ["arn:aws:dynamodb:*:${local.acct}:table/gca-*"]
  }
  statement {
    sid       = "DynamoGlobal"
    actions   = ["dynamodb:ListTables", "dynamodb:DescribeLimits"]
    resources = ["*"]
  }
  statement {
    sid       = "S3AppBuckets"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::gca-app-*", "arn:aws:s3:::gca-app-*/*"]
  }
  statement {
    sid       = "S3State"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
  }
  statement {
    sid       = "SqsSnsOnGcaNames"
    actions   = ["sqs:*", "sns:*"]
    resources = ["arn:aws:sqs:*:${local.acct}:gca-*", "arn:aws:sns:*:${local.acct}:gca-*"]
  }
  statement {
    sid       = "EventsOnGcaNames"
    actions   = ["events:*"]
    resources = ["arn:aws:events:*:${local.acct}:rule/gca-*"]
  }
  statement {
    sid       = "TagLookup"
    actions   = ["tag:GetResources"]
    resources = ["*"]
  }
  # IAM: only gca-* roles, and only when the permissions boundary is attached.
  statement {
    sid       = "CreateBoundedRoles"
    actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
    resources = ["arn:aws:iam::${local.acct}:role/gca-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.boundary.arn]
    }
  }
  statement {
    sid = "ManageGcaRoles"
    actions = [
      "iam:GetRole", "iam:DeleteRole", "iam:TagRole", "iam:UntagRole", "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole", "iam:PassRole",
    ]
    resources = ["arn:aws:iam::${local.acct}:role/gca-*"]
  }
  statement {
    sid       = "AttachOnlyBasicLogs"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = ["arn:aws:iam::${local.acct}:role/gca-*"]
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values = [
        "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
        "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
      ]
    }
  }
  statement {
    sid       = "LogsEcs"
    actions   = ["logs:*"]
    resources = ["arn:aws:logs:*:${local.acct}:log-group:/ecs/gca-*", "arn:aws:logs:*:${local.acct}:log-group:/ecs/gca-*:*"]
  }
  # --- ECS on Fargate, names gca-* only
  statement {
    sid     = "EcsOnGcaNames"
    actions = ["ecs:*"]
    resources = [
      "arn:aws:ecs:*:${local.acct}:cluster/gca-*",
      "arn:aws:ecs:*:${local.acct}:service/gca-*/*",
      "arn:aws:ecs:*:${local.acct}:task-definition/gca-*:*",
      "arn:aws:ecs:*:${local.acct}:task/gca-*/*",
    ]
  }
  statement {
    sid       = "EcsNoResourceLevel"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DeregisterTaskDefinition", "ecs:Describe*", "ecs:List*", "ecs:TagResource", "ecs:UntagResource"]
    resources = ["*"]
  }
  # --- Application Load Balancer, names gca-* only
  statement {
    sid     = "ElbOnGcaNames"
    actions = ["elasticloadbalancing:*"]
    resources = [
      "arn:aws:elasticloadbalancing:*:${local.acct}:loadbalancer/app/gca-*/*",
      "arn:aws:elasticloadbalancing:*:${local.acct}:targetgroup/gca-*/*",
      "arn:aws:elasticloadbalancing:*:${local.acct}:listener/app/gca-*/*/*",
    ]
  }
  statement {
    sid       = "ElbDescribe"
    actions   = ["elasticloadbalancing:Describe*", "elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"]
    resources = ["*"]
  }
  # --- EC2 networking: read everything, create/modify only tagged security groups
  statement {
    sid       = "Ec2Describe"
    actions   = ["ec2:Describe*", "ec2:GetSecurityGroupsForVpc"]
    resources = ["*"]
  }
  statement {
    sid       = "SgCreateOnVpc"
    actions   = ["ec2:CreateSecurityGroup"]
    resources = ["arn:aws:ec2:*:${local.acct}:vpc/*"]
  }
  statement {
    sid       = "SgCreateTagged"
    actions   = ["ec2:CreateSecurityGroup"]
    resources = ["arn:aws:ec2:*:${local.acct}:security-group/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/managed-by"
      values   = ["governed-cloud-agent"]
    }
  }
  statement {
    sid       = "SgTagOnCreate"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:*:${local.acct}:security-group/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSecurityGroup"]
    }
  }
  statement {
    sid = "SgManageOwn"
    actions = [
      "ec2:DeleteSecurityGroup", "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress", "ec2:ModifySecurityGroupRules",
    ]
    resources = ["arn:aws:ec2:*:${local.acct}:security-group/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/managed-by"
      values   = ["governed-cloud-agent"]
    }
  }
  # --- CloudFront has no name-level scoping; the policy gate enforces tags, price class and bucket policy shape
  statement {
    sid       = "CloudFront"
    actions   = ["cloudfront:*"]
    resources = ["*"]
  }
  # --- first use of ECS / ELB in an account needs their service-linked roles
  statement {
    sid     = "ServiceLinkedRoles"
    actions = ["iam:CreateServiceLinkedRole"]
    resources = [
      "arn:aws:iam::${local.acct}:role/aws-service-role/ecs.amazonaws.com/AWSServiceRoleForECS",
      "arn:aws:iam::${local.acct}:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing",
    ]
  }
  # Hard stop: nobody (including the agent) can touch the guard rails.
  statement {
    sid     = "DenyGuardrailTampering"
    effect  = "Deny"
    actions = ["iam:*"]
    resources = [
      aws_iam_policy.boundary.arn,
      "arn:aws:iam::${local.acct}:role/gca-executor",
      "arn:aws:iam::${local.acct}:role/gca-agent-app",
    ]
  }
}

resource "aws_iam_role" "executor" {
  name                 = "gca-executor"
  assume_role_policy   = data.aws_iam_policy_document.executor_trust.json
  max_session_duration = 3600
  tags                 = local.tags
}
resource "aws_iam_role_policy" "executor" {
  role   = aws_iam_role.executor.id
  name   = "executor"
  policy = data.aws_iam_policy_document.executor.json
}

# ---- Agent's own app role (chat backend running in Lambda) -------------------
data "aws_iam_policy_document" "app_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}
data "aws_iam_policy_document" "app" {
  statement {
    sid       = "Bedrock"
    actions   = ["bedrock:InvokeModel", "bedrock:Converse", "bedrock:InvokeModelWithResponseStream", "bedrock:ConverseStream"]
    resources = ["*"]
  }
  statement {
    sid = "SandboxCodeInterpreter"
    actions = [
      "bedrock-agentcore:StartCodeInterpreterSession", "bedrock-agentcore:InvokeCodeInterpreter",
      "bedrock-agentcore:StopCodeInterpreterSession", "bedrock-agentcore:GetCodeInterpreterSession",
    ]
    resources = ["arn:aws:bedrock-agentcore:us-east-1:aws:code-interpreter/aws.codeinterpreter.v1"]
  }
  statement {
    sid       = "AssumeExecutor"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.executor.arn]
  }
  statement {
    sid       = "StateBucket"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:${local.acct}:log-group:/aws/lambda/gca-agent-app*:*"]
  }
}
resource "aws_iam_role" "app" {
  name               = "gca-agent-app"
  assume_role_policy = data.aws_iam_policy_document.app_trust.json
  tags               = local.tags
}
resource "aws_iam_role_policy" "app" {
  role   = aws_iam_role.app.id
  name   = "app"
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_ecr_repository" "runner" {
  name                 = "gca-runner"
  image_tag_mutability = "MUTABLE"
  tags                 = local.tags
}

output "runner_repo" {
  value = aws_ecr_repository.runner.repository_url
}

output "account_id" {
  value = local.acct
}
output "state_bucket" {
  value = aws_s3_bucket.state.id
}
output "boundary_arn" {
  value = aws_iam_policy.boundary.arn
}
output "executor_arn" {
  value = aws_iam_role.executor.arn
}
output "app_role_arn" {
  value = aws_iam_role.app.arn
}
