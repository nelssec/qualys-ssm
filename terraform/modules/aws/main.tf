# Qualys VM Scanner - AWS Module
# Terraform alternative to CloudFormation for AWS deployments

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "deploy_hub" {
  description = "Whether to deploy hub resources"
  type        = bool
  default     = true
}

variable "deploy_spoke" {
  description = "Whether to deploy spoke resources"
  type        = bool
  default     = true
}

variable "organization_id" {
  description = "AWS Organization ID for cross-account access"
  type        = string
  default     = ""
}

variable "qualys_pod" {
  description = "Qualys POD identifier"
  type        = string
  default     = "US2"
}

variable "qualys_access_token" {
  description = "Qualys API access token"
  type        = string
  sensitive   = true
}

variable "hub_account_id" {
  description = "Hub account ID (required for spoke-only deployment)"
  type        = string
  default     = ""
}

variable "hub_bucket_name" {
  description = "Hub S3 bucket name (required for spoke-only deployment)"
  type        = string
  default     = ""
}

variable "hub_secret_arn" {
  description = "Hub secret ARN (required for spoke-only deployment)"
  type        = string
  default     = ""
}

variable "scan_types" {
  description = "Scan types to run"
  type        = string
  default     = "os,sca,fileinsight"
}

variable "enable_new_ec2_trigger" {
  description = "Enable scanning on new EC2 creation"
  type        = bool
  default     = true
}

variable "enable_scheduled_scan" {
  description = "Enable scheduled scanning"
  type        = bool
  default     = true
}

variable "schedule_expression" {
  description = "Cron schedule for automated scans"
  type        = string
  default     = "cron(0 2 * * ? *)"
}

variable "result_retention_days" {
  description = "Number of days to retain scan results"
  type        = number
  default     = 90
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  bucket_name = var.deploy_hub ? "qualys-ssm-hub-${local.account_id}" : var.hub_bucket_name
}

# =============================================================================
# HUB RESOURCES
# =============================================================================

resource "aws_s3_bucket" "results" {
  count  = var.deploy_hub ? 1 : 0
  bucket = local.bucket_name
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  count  = var.deploy_hub ? 1 : 0
  bucket = aws_s3_bucket.results[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "results" {
  count  = var.deploy_hub ? 1 : 0
  bucket = aws_s3_bucket.results[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "results" {
  count  = var.deploy_hub ? 1 : 0
  bucket = aws_s3_bucket.results[0].id

  rule {
    id     = "expire-results"
    status = "Enabled"

    expiration {
      days = var.result_retention_days
    }
  }
}

resource "aws_s3_bucket_policy" "results" {
  count  = var.deploy_hub && var.organization_id != "" ? 1 : 0
  bucket = aws_s3_bucket.results[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecure"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.results[0].arn,
          "${aws_s3_bucket.results[0].arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
      {
        Sid       = "AllowOrgAccess"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:PutObject", "s3:GetObject"]
        Resource  = "${aws_s3_bucket.results[0].arn}/*"
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = var.organization_id
          }
        }
      }
    ]
  })
}

resource "aws_secretsmanager_secret" "qualys" {
  count       = var.deploy_hub ? 1 : 0
  name        = "qualys-ssm-scanner-credentials"
  description = "Qualys credentials for SSM scanner"
}

resource "aws_secretsmanager_secret_version" "qualys" {
  count     = var.deploy_hub ? 1 : 0
  secret_id = aws_secretsmanager_secret.qualys[0].id
  secret_string = jsonencode({
    qualys_pod          = var.qualys_pod
    qualys_access_token = var.qualys_access_token
  })
}

# =============================================================================
# SPOKE RESOURCES (placeholder - full implementation mirrors CloudFormation)
# =============================================================================

# Note: Full spoke implementation with Lambda, Step Functions, SSM Document,
# EventBridge rules mirrors the CloudFormation template. For brevity, this
# module provides the structure - expand as needed.

# =============================================================================
# OUTPUTS
# =============================================================================

output "hub_bucket_name" {
  description = "Name of the hub S3 bucket"
  value       = var.deploy_hub ? aws_s3_bucket.results[0].id : var.hub_bucket_name
}

output "hub_bucket_arn" {
  description = "ARN of the hub S3 bucket"
  value       = var.deploy_hub ? aws_s3_bucket.results[0].arn : null
}

output "hub_secret_arn" {
  description = "ARN of the Qualys credentials secret"
  value       = var.deploy_hub ? aws_secretsmanager_secret.qualys[0].arn : var.hub_secret_arn
}

output "hub_account_id" {
  description = "Hub account ID"
  value       = local.account_id
}
