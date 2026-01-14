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

variable "target_zones" {
  description = "Zones to target for OS Config policy (e.g., us-central1-a,us-central1-b)"
  type        = list(string)
  default     = []
}

locals {
  function_name = "qualys-vm-scanner"
  scanner_script = <<-EOT
#!/bin/bash
set -e

QSCANNER="/opt/qualys/qscanner"
TRIGGER_FILE="/tmp/qualys-scan-trigger"
LOCK_FILE="/tmp/qualys-scan.lock"

if [ -f "$LOCK_FILE" ]; then
  LOCK_AGE=$(( ($(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)) ))
  if [ "$LOCK_AGE" -lt 900 ]; then
    echo "Scan already in progress"
    exit 0
  fi
  rm -f "$LOCK_FILE"
fi

SCAN_REQUESTED=$(curl -s -f -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/qualys-scan-trigger" 2>/dev/null || echo "")

if [ -z "$SCAN_REQUESTED" ] || [ "$SCAN_REQUESTED" = "false" ]; then
  exit 0
fi

touch "$LOCK_FILE"
trap "rm -f $LOCK_FILE" EXIT

mkdir -p /opt/qualys

INSTANCE_NAME=$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/name")
ZONE=$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/zone" | cut -d'/' -f4)
PROJECT_ID=$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/project/project-id")
MACHINE_TYPE=$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/machine-type" | cut -d'/' -f4)

ARCH=$(uname -m)
case $ARCH in
  x86_64) PLATFORM="linux-amd64" ;;
  aarch64|arm64) PLATFORM="linux-arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

case $PLATFORM in
  linux-amd64) QSCANNER_URL="https://github.com/nelssec/qualys-lambda/raw/main/scanner-lambda/qscanner.gz" ;;
  linux-arm64) QSCANNER_URL="https://github.com/nelssec/qualys-lambda/raw/main/scanner-lambda/qscanner-arm64.gz" ;;
esac

QSCANNER_SHA="/opt/qualys/qscanner.sha256"
REFRESH_DAYS=30
NEED_DOWNLOAD=false

if [ ! -f "$QSCANNER" ]; then
  NEED_DOWNLOAD=true
else
  FILE_AGE=$(( ($(date +%s) - $(stat -c %Y "$QSCANNER")) / 86400 ))
  if [ "$FILE_AGE" -gt "$REFRESH_DAYS" ]; then
    LOCAL_SHA=$(cat "$QSCANNER_SHA" 2>/dev/null || echo "")
    REMOTE_SHA=$(curl -sL "$${QSCANNER_URL}.sha256" 2>/dev/null || echo "")
    if [ -n "$LOCAL_SHA" ] && [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
      touch "$QSCANNER"
    else
      NEED_DOWNLOAD=true
    fi
  fi
fi

if [ "$NEED_DOWNLOAD" = "true" ]; then
  curl -sL "$QSCANNER_URL" -o /tmp/qscanner.gz
  sha256sum /tmp/qscanner.gz | awk '{print $1}' > "$QSCANNER_SHA"
  gunzip -c /tmp/qscanner.gz > $QSCANNER
  chmod +x $QSCANNER
  rm -f /tmp/qscanner.gz
fi

HUB_PROJECT="${hub_project_id}"
HUB_SECRET="${hub_secret_id}"
HUB_BUCKET="${hub_bucket_name}"
SCAN_TYPES="${scan_types}"

ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null || curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" | \
  grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

SECRET_JSON=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://secretmanager.googleapis.com/v1/projects/$HUB_PROJECT/secrets/$HUB_SECRET/versions/latest:access" | \
  grep -o '"data":"[^"]*"' | cut -d'"' -f4 | base64 -d)

export QUALYS_ACCESS_TOKEN=$(echo $SECRET_JSON | grep -o '"qualys_access_token":"[^"]*"' | cut -d'"' -f4)
POD=$(echo $SECRET_JSON | grep -o '"qualys_pod":"[^"]*"' | cut -d'"' -f4)

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="/tmp/qscanner-$${INSTANCE_NAME}-$${TIMESTAMP}"
mkdir -p $OUTPUT

$QSCANNER \
  --pod $POD \
  --mode get-report \
  --scan-types $SCAN_TYPES \
  --shell-commands "uname -a=$(uname -a)" \
  --exclude-dirs /proc,/sys,/dev,/run,/tmp,/var/lib/docker \
  --scan-target-info "instance_name=$${INSTANCE_NAME}" \
  --scan-target-info "project_id=$${PROJECT_ID}" \
  --scan-target-info "zone=$${ZONE}" \
  --scan-target-info "machine_type=$${MACHINE_TYPE}" \
  --report-format json,sarif \
  -o $OUTPUT \
  rootfs /

gsutil -m cp -r "$OUTPUT/*" "gs://$HUB_BUCKET/scans/$PROJECT_ID/$INSTANCE_NAME/$TIMESTAMP/"

rm -rf $OUTPUT

gcloud compute instances remove-metadata "$INSTANCE_NAME" --zone="$ZONE" --keys=qualys-scan-trigger 2>/dev/null || true
EOT
}

resource "google_project_service" "apis" {
  for_each = toset([
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudscheduler.googleapis.com",
    "pubsub.googleapis.com",
    "secretmanager.googleapis.com",
    "compute.googleapis.com",
    "logging.googleapis.com",
    "run.googleapis.com",
    "osconfig.googleapis.com",
  ])
  project = var.project_id
  service = each.value
}

resource "google_service_account" "scanner" {
  project      = var.project_id
  account_id   = "qualys-scanner"
  display_name = "Qualys VM Scanner"
}

resource "google_secret_manager_secret_iam_member" "scanner_secret_access" {
  project   = var.hub_project_id
  secret_id = var.hub_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.scanner.email}"
}

resource "google_storage_bucket_iam_member" "scanner_bucket_access" {
  bucket = var.hub_bucket_name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.scanner.email}"
}

resource "google_project_iam_member" "scanner_compute_admin" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.scanner.email}"
}

resource "google_project_iam_member" "scanner_osconfig_admin" {
  project = var.project_id
  role    = "roles/osconfig.osPolicyAssignmentAdmin"
  member  = "serviceAccount:${google_service_account.scanner.email}"
}

resource "google_pubsub_topic" "scan_trigger" {
  project = var.project_id
  name    = "qualys-scan-trigger"

  message_retention_duration = "86400s"
}

resource "google_pubsub_subscription" "scan_trigger" {
  project = var.project_id
  name    = "qualys-scan-trigger-sub"
  topic   = google_pubsub_topic.scan_trigger.name

  ack_deadline_seconds       = 600
  message_retention_duration = "86400s"

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  expiration_policy {
    ttl = ""
  }
}

resource "google_storage_bucket" "function_source" {
  project                     = var.project_id
  name                        = "qualys-scanner-source-${var.project_id}"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 3
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_os_config_os_policy_assignment" "qualys_scanner" {
  name     = "qualys-scanner-policy"
  project  = var.project_id
  location = var.region

  instance_filter {
    all = false
    inclusion_labels {
      labels = {
        "qualys-scan" = "enabled"
      }
    }
  }

  rollout {
    disruption_budget {
      fixed = 10
    }
    min_wait_duration = "60s"
  }

  os_policies {
    id   = "qualys-scanner"
    mode = "ENFORCEMENT"

    resource_groups {
      resources {
        id = "run-qualys-scan"
        exec {
          validate {
            interpreter = "SHELL"
            script      = "exit 0"
          }
          enforce {
            interpreter = "SHELL"
            script      = local.scanner_script
          }
        }
      }
    }

    allow_no_resource_group_match = true
  }

  depends_on = [google_project_service.apis]
}

resource "google_cloudfunctions2_function" "scanner" {
  project  = var.project_id
  name     = local.function_name
  location = var.region

  build_config {
    runtime     = "python312"
    entry_point = "trigger_scan"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = "function-source.zip"
      }
    }
  }

  service_config {
    max_instance_count             = 10
    min_instance_count             = 0
    available_memory               = "256M"
    timeout_seconds                = 540
    service_account_email          = google_service_account.scanner.email
    ingress_settings               = "ALLOW_INTERNAL_AND_GCLB"
    all_traffic_on_latest_revision = true

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

resource "google_pubsub_topic_iam_member" "sink_publisher" {
  count = var.enable_new_vm_trigger ? 1 : 0

  project = var.project_id
  topic   = google_pubsub_topic.scan_trigger.name
  role    = "roles/pubsub.publisher"
  member  = google_logging_project_sink.new_vm_sink[0].writer_identity
}

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

output "os_policy_assignment" {
  description = "OS Config policy assignment for Qualys scanning"
  value       = google_os_config_os_policy_assignment.qualys_scanner.name
}
