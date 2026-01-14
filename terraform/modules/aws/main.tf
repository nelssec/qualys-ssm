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

resource "aws_kms_key" "qualys" {
  count                   = var.deploy_hub ? 1 : 0
  description             = "Qualys SSM Scanner encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid    = "EnableIAMPolicies"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowS3Service"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action   = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource = "*"
      }
      ],
      var.organization_id != "" ? [{
        Sid       = "AllowOrganizationAccess"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = var.organization_id
          }
        }
      }] : []
    )
  })
}

resource "aws_kms_alias" "qualys" {
  count         = var.deploy_hub ? 1 : 0
  name          = "alias/qualys-ssm-scanner"
  target_key_id = aws_kms_key.qualys[0].key_id
}

resource "aws_s3_bucket" "logs" {
  count  = var.deploy_hub ? 1 : 0
  bucket = "qualys-ssm-logs-${local.account_id}"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  count  = var.deploy_hub ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.qualys[0].arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  count  = var.deploy_hub ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "logs" {
  count  = var.deploy_hub ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  count  = var.deploy_hub ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    expiration {
      days = 365
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  count  = var.deploy_hub ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ServerAccessLogsPolicy"
        Effect = "Allow"
        Principal = {
          Service = "logging.s3.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.logs[0].arn}/*"
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:s3:::${local.bucket_name}"
          }
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      },
      {
        Sid       = "DenyInsecure"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.logs[0].arn,
          "${aws_s3_bucket.logs[0].arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket" "results" {
  count      = var.deploy_hub ? 1 : 0
  bucket     = local.bucket_name
  depends_on = [aws_s3_bucket_policy.logs]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  count  = var.deploy_hub ? 1 : 0
  bucket = aws_s3_bucket.results[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.qualys[0].arn
    }
    bucket_key_enabled = true
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

resource "aws_s3_bucket_versioning" "results" {
  count  = var.deploy_hub ? 1 : 0
  bucket = aws_s3_bucket.results[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_logging" "results" {
  count  = var.deploy_hub ? 1 : 0
  bucket = aws_s3_bucket.results[0].id

  target_bucket = aws_s3_bucket.logs[0].id
  target_prefix = "s3-access-logs/"
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

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
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
  kms_key_id  = aws_kms_key.qualys[0].arn
}

resource "aws_secretsmanager_secret_version" "qualys" {
  count     = var.deploy_hub ? 1 : 0
  secret_id = aws_secretsmanager_secret.qualys[0].id
  secret_string = jsonencode({
    qualys_pod          = var.qualys_pod
    qualys_access_token = var.qualys_access_token
  })
}

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

output "hub_logs_bucket_name" {
  description = "Name of the hub logs S3 bucket"
  value       = var.deploy_hub ? aws_s3_bucket.logs[0].id : null
}

output "hub_kms_key_arn" {
  description = "ARN of the hub KMS key"
  value       = var.deploy_hub ? aws_kms_key.qualys[0].arn : null
}

output "hub_kms_key_id" {
  description = "ID of the hub KMS key"
  value       = var.deploy_hub ? aws_kms_key.qualys[0].key_id : null
}
