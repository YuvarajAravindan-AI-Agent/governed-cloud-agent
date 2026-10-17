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
  type = string
}
variable "boundary_arn" {
  type = string
}
variable "public" {
  type    = bool
  default = true
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "me" {}
data "aws_vpc" "default" {
  default = true
}
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

locals {
  acct   = data.aws_caller_identity.me.account_id
  name   = "gca-${var.app_name}-${substr(var.session_id, 0, 6)}"
  bucket = "gca-app-${var.app_name}-${substr(var.session_id, 0, 6)}-${data.aws_caller_identity.me.account_id}"
  tags = {
    "gca-session" = var.session_id
    "gca-expires" = var.expires
    "managed-by"  = "governed-cloud-agent"
    "exposure"    = "public"
  }
  runner_image = "${data.aws_caller_identity.me.account_id}.dkr.ecr.us-east-1.amazonaws.com/gca-runner:v1"
}

# ---- app bundle: the runner image downloads this zip at start ----
data "archive_file" "code" {
  type        = "zip"
  source_dir  = "${path.module}/app"
  output_path = "${path.module}/app.zip"
}

resource "aws_s3_bucket" "bundle" {
  bucket        = local.bucket
  force_destroy = true
  tags          = local.tags
}
resource "aws_s3_bucket_public_access_block" "bundle" {
  bucket                  = aws_s3_bucket.bundle.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_object" "bundle" {
  bucket = aws_s3_bucket.bundle.id
  key    = "bundle.zip"
  source = data.archive_file.code.output_path
  etag   = data.archive_file.code.output_md5
}

# ---- IAM: execution role (pull image, write logs) and task role (read own bundle) ----
data "aws_iam_policy_document" "ecs_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "exec" {
  name                 = "${local.name}-exec"
  assume_role_policy   = data.aws_iam_policy_document.ecs_trust.json
  permissions_boundary = var.boundary_arn
  tags                 = local.tags
}
resource "aws_iam_role_policy_attachment" "exec" {
  role       = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name                 = "${local.name}-task"
  assume_role_policy   = data.aws_iam_policy_document.ecs_trust.json
  permissions_boundary = var.boundary_arn
  tags                 = local.tags
}
resource "aws_iam_role_policy" "task" {
  name = "read-bundle"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = ["arn:aws:s3:::${local.bucket}/bundle.zip"]
    }]
  })
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}"
  retention_in_days = 3
  tags              = local.tags
}

# ---- network: ALB open on 80 only; tasks reachable only from the ALB ----
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "ALB ingress 80"
  vpc_id      = data.aws_vpc.default.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_security_group" "task" {
  name        = "${local.name}-task"
  description = "Task ingress from ALB only"
  vpc_id      = data.aws_vpc.default.id
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_lb" "app" {
  name               = substr(local.name, 0, 32)
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
  tags               = local.tags
}

resource "aws_lb_target_group" "app" {
  name        = substr(local.name, 0, 32)
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.default.id
  health_check {
    path     = "/"
    matcher  = "200-499"
    interval = 15
  }
  deregistration_delay = 5
  tags                 = local.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
  tags = local.tags
}

# ---- ECS ----
resource "aws_ecs_cluster" "app" {
  name = local.name
  tags = local.tags
}

resource "aws_ecs_task_definition" "app" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions = jsonencode([{
    name         = "app"
    image        = local.runner_image
    essential    = true
    portMappings = [{ containerPort = 8080, protocol = "tcp" }]
    environment = [
      { name = "BUNDLE_BUCKET", value = local.bucket },
      { name = "BUNDLE_KEY", value = "bundle.zip" },
      { name = "BUNDLE_ETAG", value = data.archive_file.code.output_md5 },
      { name = "PORT", value = "8080" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = "/ecs/${local.name}"
        awslogs-region        = "us-east-1"
        awslogs-stream-prefix = "app"
      }
    }
  }])
  tags       = local.tags
  depends_on = [aws_cloudwatch_log_group.app, aws_s3_object.bundle]
}

resource "aws_ecs_service" "app" {
  name            = local.name
  cluster         = aws_ecs_cluster.app.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 8080
  }
  health_check_grace_period_seconds = 60
  tags                              = local.tags
  depends_on                        = [aws_lb_listener.http, aws_iam_role_policy_attachment.exec, aws_iam_role_policy.task]
}

output "url" {
  value = "http://${aws_lb.app.dns_name}"
}
output "function" {
  value = aws_ecs_service.app.name
}
