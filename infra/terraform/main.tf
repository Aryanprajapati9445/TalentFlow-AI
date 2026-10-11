data "aws_caller_identity" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  bucket_name = "${var.project_name}-${random_id.suffix.hex}"

  github_subject = "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/${var.github_branch}"

  common_tags = {
    Project     = var.project_name
    ManagedBy   = "Terraform"
    Environment = "portfolio"
  }
}

# Private S3 bucket
resource "aws_s3_bucket" "site" {
  bucket = local.bucket_name
  tags   = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# CloudFront Origin Access Control
resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.project_name}-oac"
  description                       = "Private S3 access for TalentFlow-AI"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  comment             = "TalentFlow-AI static frontend"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "talentflow-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "talentflow-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = local.common_tags
}

# Permit only this CloudFront distribution to read the bucket
resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontReadOnly"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = ["s3:GetObject"]
      Resource  = "${aws_s3_bucket.site.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.site.arn
        }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.site]
}

# GitHub OIDC provider
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # Verify the currently valid GitHub OIDC certificate thumbprint
  # against official AWS/GitHub guidance before applying.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Trust only the designated repository branch
resource "aws_iam_role" "github_deploy" {
  name = "TalentFlowGitHubDeploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.github_subject
        }
      }
    }]
  })

  tags = local.common_tags
}

# Deployment role: upload website assets and invalidate this distribution
resource "aws_iam_role_policy" "github_deploy" {
  name = "TalentFlowStaticDeployment"
  role = aws_iam_role.github_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = [aws_s3_bucket.site.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = ["${aws_s3_bucket.site.arn}/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "cloudfront:CreateInvalidation"
        ]
        Resource = [aws_cloudfront_distribution.site.arn]
      }
    ]
  })
}

# Optional CloudWatch alarm for elevated CloudFront 5xx error rate
resource "aws_cloudwatch_metric_alarm" "cloudfront_5xx" {
  alarm_name          = "${var.project_name}-cloudfront-5xx"
  alarm_description   = "Elevated CloudFront server error rate"
  namespace           = "AWS/CloudFront"
  metric_name         = "5xxErrorRate"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DistributionId = aws_cloudfront_distribution.site.id
    Region         = "Global"
  }

  tags = local.common_tags
}

# Optional email notification for the CloudWatch alarm
resource "aws_sns_topic" "alerts" {
  count = var.alert_email != "" ? 1 : 0
  name  = "${var.project_name}-alerts"
  tags  = local.common_tags
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "cloudfront_5xx_email" {
  count               = var.alert_email != "" ? 1 : 0
  alarm_name          = "${var.project_name}-cloudfront-5xx-email"
  alarm_description   = "CloudFront 5xx errors requiring investigation"
  namespace           = "AWS/CloudFront"
  metric_name         = "5xxErrorRate"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts[0].arn]

  dimensions = {
    DistributionId = aws_cloudfront_distribution.site.id
    Region         = "Global"
  }

  tags = local.common_tags
}

resource "aws_budgets_budget" "monthly" {
  name         = "TalentFlowAI-Monthly-Budget"
  budget_type  = "COST"
  limit_amount = "5"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = false
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.alert_email != "" ? [var.alert_email] : []
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.alert_email != "" ? [var.alert_email] : []
  }
}