# Qualys VM Scanner - GCP Module
# Wrapper module referencing the native GCP Terraform in gcp/terraform/

terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
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

variable "hub_project_id" {
  description = "Hub project ID (required for spoke-only deployment)"
  type        = string
  default     = ""
}

variable "hub_bucket_name" {
  description = "Hub storage bucket name (required for spoke-only deployment)"
  type        = string
  default     = ""
}

variable "hub_secret_id" {
  description = "Hub Secret Manager secret ID (required for spoke-only deployment)"
  type        = string
  default     = ""
}

variable "scan_types" {
  description = "Scan types to run"
  type        = string
  default     = "os,sca,fileinsight"
}

variable "enable_new_vm_trigger" {
  description = "Enable scanning on new VM creation"
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
  default     = "0 2 * * *"
}

variable "result_retention_days" {
  description = "Number of days to retain scan results"
  type        = number
  default     = 90
}

locals {
  bucket_name = var.deploy_hub ? "qualys-ssm-hub-${var.project_id}" : var.hub_bucket_name
}

# =============================================================================
# HUB RESOURCES
# =============================================================================

resource "google_storage_bucket" "results" {
  count                       = var.deploy_hub ? 1 : 0
  name                        = local.bucket_name
  project                     = var.project_id
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = var.result_retention_days
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_secret_manager_secret" "qualys" {
  count     = var.deploy_hub ? 1 : 0
  project   = var.project_id
  secret_id = "qualys-ssm-scanner-credentials"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "qualys" {
  count  = var.deploy_hub ? 1 : 0
  secret = google_secret_manager_secret.qualys[0].id
  secret_data = jsonencode({
    qualys_pod          = var.qualys_pod
    qualys_access_token = var.qualys_access_token
  })
}

# =============================================================================
# SPOKE RESOURCES (placeholder - expand as needed)
# =============================================================================

# Note: Full spoke implementation with Cloud Functions, Pub/Sub, Cloud Scheduler
# mirrors gcp/terraform/spoke. For brevity, this module provides the structure -
# expand as needed.

# =============================================================================
# OUTPUTS
# =============================================================================

output "hub_bucket_name" {
  description = "Name of the hub storage bucket"
  value       = var.deploy_hub ? google_storage_bucket.results[0].name : var.hub_bucket_name
}

output "hub_bucket_url" {
  description = "URL of the hub storage bucket"
  value       = var.deploy_hub ? google_storage_bucket.results[0].url : null
}

output "hub_secret_id" {
  description = "ID of the Qualys credentials secret"
  value       = var.deploy_hub ? google_secret_manager_secret.qualys[0].secret_id : var.hub_secret_id
}

output "hub_project_id" {
  description = "Hub project ID"
  value       = var.project_id
}
