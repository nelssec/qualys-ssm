# Qualys VM Scanner - Spoke (Per-Project Resources)
# Deploys: Cloud Functions + Pub/Sub + Cloud Scheduler for VM scanning

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
  description = "GCP Project ID for spoke resources"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "hub_project_id" {
  description = "Hub project ID"
  type        = string
}

variable "hub_bucket_name" {
  description = "Hub storage bucket name"
  type        = string
}

variable "hub_secret_id" {
  description = "Hub Secret Manager secret ID"
  type        = string
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

locals {
  function_name = "qualys-vm-scanner"
}

# Enable required APIs
resource "google_project_service" "apis" {
  for_each = toset([
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudscheduler.googleapis.com",
    "pubsub.googleapis.com",
    "secretmanager.googleapis.com",
    "compute.googleapis.com",
    "logging.googleapis.com",
  ])
  project = var.project_id
  service = each.value
}

# Service account for Cloud Function
resource "google_service_account" "scanner" {
  project      = var.project_id
  account_id   = "qualys-scanner"
  display_name = "Qualys VM Scanner"
}

# IAM: Scanner can read secrets from hub project
resource "google_secret_manager_secret_iam_member" "scanner_secret_access" {
  project   = var.hub_project_id
  secret_id = var.hub_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.scanner.email}"
}

# IAM: Scanner can write to hub bucket
resource "google_storage_bucket_iam_member" "scanner_bucket_access" {
  bucket = var.hub_bucket_name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.scanner.email}"
}

# IAM: Scanner can invoke commands on VMs
resource "google_project_iam_member" "scanner_compute_admin" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.scanner.email}"
}

# Pub/Sub topic for scan triggers
resource "google_pubsub_topic" "scan_trigger" {
  project = var.project_id
  name    = "qualys-scan-trigger"
}

# Pub/Sub subscription for the function
resource "google_pubsub_subscription" "scan_trigger" {
  project = var.project_id
  name    = "qualys-scan-trigger-sub"
  topic   = google_pubsub_topic.scan_trigger.name

  ack_deadline_seconds = 600

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
}

# Cloud Storage bucket for function source
resource "google_storage_bucket" "function_source" {
  project                     = var.project_id
  name                        = "qualys-scanner-source-${var.project_id}"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }
}

# Cloud Function (Gen2) for scan orchestration
resource "google_cloudfunctions2_function" "scanner" {
  project  = var.project_id
  name     = local.function_name
  location = var.region

  build_config {
    runtime     = "python311"
    entry_point = "trigger_scan"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = "function-source.zip" # Placeholder - actual source deployed separately
      }
    }
  }

  service_config {
    max_instance_count    = 10
    min_instance_count    = 0
    available_memory      = "256M"
    timeout_seconds       = 540
    service_account_email = google_service_account.scanner.email

    environment_variables = {
      HUB_PROJECT_ID  = var.hub_project_id
      HUB_BUCKET_NAME = var.hub_bucket_name
      HUB_SECRET_ID   = var.hub_secret_id
      SCAN_TYPES      = var.scan_types
      PROJECT_ID      = var.project_id
    }
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.scan_trigger.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }

  depends_on = [google_project_service.apis]
}

# Cloud Scheduler for daily scans
resource "google_cloud_scheduler_job" "daily_scan" {
  count = var.enable_scheduled_scan ? 1 : 0

  project     = var.project_id
  name        = "qualys-daily-scan"
  description = "Trigger daily Qualys vulnerability scan"
  schedule    = var.schedule_expression
  time_zone   = "UTC"
  region      = var.region

  pubsub_target {
    topic_name = google_pubsub_topic.scan_trigger.id
    data       = base64encode("{\"scan_type\": \"fleet\"}")
  }

  depends_on = [google_project_service.apis]
}

# Log sink for new VM events (triggers scan on VM creation)
resource "google_logging_project_sink" "new_vm_sink" {
  count = var.enable_new_vm_trigger ? 1 : 0

  project     = var.project_id
  name        = "qualys-new-vm-trigger"
  destination = "pubsub.googleapis.com/${google_pubsub_topic.scan_trigger.id}"

  filter = <<-EOT
    resource.type="gce_instance"
    protoPayload.methodName="v1.compute.instances.insert"
    protoPayload.response.status="RUNNING"
  EOT

  unique_writer_identity = true
}

# Grant the log sink permission to publish to Pub/Sub
resource "google_pubsub_topic_iam_member" "sink_publisher" {
  count = var.enable_new_vm_trigger ? 1 : 0

  project = var.project_id
  topic   = google_pubsub_topic.scan_trigger.name
  role    = "roles/pubsub.publisher"
  member  = google_logging_project_sink.new_vm_sink[0].writer_identity
}

# Outputs
output "function_name" {
  description = "Name of the scanner Cloud Function"
  value       = google_cloudfunctions2_function.scanner.name
}

output "function_url" {
  description = "URL of the scanner Cloud Function"
  value       = google_cloudfunctions2_function.scanner.service_config[0].uri
}

output "service_account_email" {
  description = "Email of the scanner service account"
  value       = google_service_account.scanner.email
}

output "pubsub_topic" {
  description = "Pub/Sub topic for triggering scans"
  value       = google_pubsub_topic.scan_trigger.name
}
