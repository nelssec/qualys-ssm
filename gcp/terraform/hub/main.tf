# Qualys VM Scanner - Hub (Central Resources)
# Deploys: Cloud Storage + Secret Manager for centralized credential and result storage

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
  description = "GCP Project ID for hub resources"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "qualys_pod" {
  description = "Qualys POD identifier"
  type        = string
  default     = "US2"
  validation {
    condition     = contains(["US1", "US2", "US3", "US4", "EU1", "EU2", "IN1", "CA1", "AE1", "UK1", "AU1"], var.qualys_pod)
    error_message = "Invalid Qualys POD."
  }
}

variable "qualys_access_token" {
  description = "Qualys API access token"
  type        = string
  sensitive   = true
}

variable "allowed_org_id" {
  description = "GCP Organization ID for cross-project access"
  type        = string
  default     = ""
}

variable "allowed_folder_ids" {
  description = "GCP Folder IDs allowed to access hub resources"
  type        = list(string)
  default     = []
}

variable "result_retention_days" {
  description = "Number of days to retain scan results"
  type        = number
  default     = 90
}

locals {
  bucket_name = "qualys-ssm-hub-${var.project_id}"
}

# Cloud Storage bucket for scan results
resource "google_storage_bucket" "results" {
  name                        = local.bucket_name
  project                     = var.project_id
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true

  versioning {
    enabled = false
  }

  lifecycle_rule {
    condition {
      age = var.result_retention_days
    }
    action {
      type = "Delete"
    }
  }

  encryption {
    default_kms_key_name = null # Uses Google-managed encryption
  }
}

# Secret Manager secret for Qualys credentials
resource "google_secret_manager_secret" "qualys_credentials" {
  project   = var.project_id
  secret_id = "qualys-ssm-scanner-credentials"

  replication {
    auto {}
  }
}

# Store the credentials as a JSON secret version
resource "google_secret_manager_secret_version" "qualys_credentials" {
  secret = google_secret_manager_secret.qualys_credentials.id
  secret_data = jsonencode({
    qualys_pod          = var.qualys_pod
    qualys_access_token = var.qualys_access_token
  })
}

# IAM binding for cross-project access to storage bucket
# Spoke projects' service accounts will need storage.objectCreator role
resource "google_storage_bucket_iam_member" "spoke_access" {
  count  = var.allowed_org_id != "" ? 1 : 0
  bucket = google_storage_bucket.results.name
  role   = "roles/storage.objectCreator"
  member = "domain:${var.allowed_org_id}" # Adjust based on your org structure
}

# Outputs for spoke deployment
output "bucket_name" {
  description = "Name of the results storage bucket"
  value       = google_storage_bucket.results.name
}

output "bucket_url" {
  description = "URL of the results storage bucket"
  value       = google_storage_bucket.results.url
}

output "secret_name" {
  description = "Name of the Qualys credentials secret"
  value       = google_secret_manager_secret.qualys_credentials.secret_id
}

output "secret_id" {
  description = "Full resource ID of the Qualys credentials secret"
  value       = google_secret_manager_secret.qualys_credentials.id
}

output "hub_project_id" {
  description = "Hub project ID"
  value       = var.project_id
}
