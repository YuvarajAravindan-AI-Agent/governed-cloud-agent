terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
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

locals {
  name   = "gca-${var.app_name}-${substr(var.session_id, 0, 6)}"
  bucket = "gca-app-${var.app_name}-${substr(var.session_id, 0, 6)}-${data.aws_caller_identity.me.account_id}"
  tags = {
    "gca-session" = var.session_id
    "gca-expires" = var.expires
    "managed-by"  = "governed-cloud-agent"
    "exposure"    = "public"
  }
  types = {
    html = "text/html; charset=utf-8", css = "text/css", js = "application/javascript", json = "application/json",
    svg = "image/svg+xml", txt = "text/plain", xml = "application/xml", ico = "image/x-icon", md = "text/plain",
  }
}

resource "aws_s3_bucket" "site" {
  bucket        = local.bucket
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "files" {
  for_each     = fileset("${path.module}/site", "**")
  bucket       = aws_s3_bucket.site.id
  key          = each.value
  source       = "${path.module}/site/${each.value}"
  etag         = filemd5("${path.module}/site/${each.value}")
  content_type = lookup(local.types, reverse(split(".", each.value))[0], "application/octet-stream")
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = local.name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  comment             = local.name
  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }
  default_cache_behavior {
    target_origin_id       = "s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    compress               = true
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  viewer_certificate {
    cloudfront_default_certificate = true
  }
  tags = local.tags
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.site.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.site.arn } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.site]
}

output "url" {
  value = "https://${aws_cloudfront_distribution.site.domain_name}"
}
output "function" {
  value = aws_cloudfront_distribution.site.id
}
