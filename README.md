# Qualys VM Scanner

Multi-cloud VM vulnerability scanning using Qualys QScanner with cloud-native services.

## Supported Clouds

| Cloud | IaC | Hub Resources | Spoke Resources |
|-------|-----|---------------|-----------------|
| AWS | CloudFormation | S3 + Secrets Manager | SSM + Lambda + Step Functions + EventBridge |
| Azure | Bicep | Storage Account + Key Vault | Functions + Automation + Event Grid |
| GCP | Terraform | Cloud Storage + Secret Manager | Cloud Functions + Pub/Sub + Scheduler |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              HUB (Central)                                   │
│  ┌─────────────────────────────────────────────────────────────────────────┐ │
│  │  AWS: S3 + Secrets Manager                                              │ │
│  │  Azure: Storage Account + Key Vault                                     │ │
│  │  GCP: Cloud Storage + Secret Manager                                    │ │
│  └─────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │ cross-account/subscription/project
┌──────────────────────────────────┴──────────────────────────────────────────┐
│                           SPOKE (Per Account)                                │
│  ┌─────────────────────────────────────────────────────────────────────────┐ │
│  │  Event Trigger ──► Orchestration ──► VM Agent ──► QScanner              │ │
│  │                                                                         │ │
│  │  AWS:   EventBridge ──► Step Functions ──► SSM ──► EC2                  │ │
│  │  Azure: Event Grid ──► Durable Functions ──► Run Command ──► VM         │ │
│  │  GCP:   Pub/Sub ──► Cloud Functions ──► OS Config ──► Compute           │ │
│  └─────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Project Structure

```
qualys-ssm/
├── aws/
│   └── cloudformation/
│       ├── hub.yaml              # S3 bucket + Secrets Manager policy
│       └── spoke.yaml            # Lambda + Step Functions + SSM Document
├── azure/
│   └── bicep/
│       ├── hub.bicep             # Storage Account + Key Vault
│       └── spoke.bicep           # Functions + Automation Account
├── gcp/
│   └── terraform/
│       ├── hub/                  # Cloud Storage + Secret Manager
│       └── spoke/                # Cloud Functions + Pub/Sub + Scheduler
├── terraform/                    # Optional: Unified Terraform for all clouds
│   ├── modules/
│   │   ├── aws/
│   │   ├── azure/
│   │   └── gcp/
│   └── examples/
│       └── multi-cloud/
├── Makefile
└── README.md
```

## Quick Start

### Authentication

```bash
export QUALYS_ACCESS_TOKEN="your-access-token"
export QUALYS_POD=US2  # US1, US2, US3, US4, EU1, EU2, IN1, CA1, AE1, UK1, AU1
```

### AWS Deployment

```bash
# Deploy hub (security account)
make aws-deploy-hub ORG_ID=o-xxxxxxxxxx

# Get hub outputs
make aws-status-hub

# Deploy spokes via StackSet
HUB_ACCOUNT_ID=123456789012 \
HUB_BUCKET=qualys-ssm-hub-123456789012 \
make aws-deploy-stackset

make aws-deploy-stackset-instances OU_IDS=ou-xxxx-xxxxxxxx

# Or deploy single spoke
HUB_ACCOUNT_ID=123456789012 \
HUB_BUCKET=qualys-ssm-hub-123456789012 \
make aws-deploy-spoke
```

### Azure Deployment

```bash
# Deploy hub
make azure-deploy-hub AZURE_RESOURCE_GROUP=qualys-hub-rg

# Deploy spoke
HUB_SUBSCRIPTION_ID=xxx \
HUB_RESOURCE_GROUP=qualys-hub-rg \
HUB_STORAGE_ACCOUNT=qualysscanxxx \
HUB_KEY_VAULT=qualys-hub-xxx \
make azure-deploy-spoke AZURE_RESOURCE_GROUP=qualys-spoke-rg
```

### GCP Deployment

```bash
# Deploy hub
make gcp-deploy-hub GCP_PROJECT=my-hub-project

# Deploy spoke
HUB_PROJECT_ID=my-hub-project \
HUB_BUCKET_NAME=qualys-ssm-hub-my-hub-project \
HUB_SECRET_ID=qualys-ssm-scanner-credentials \
make gcp-deploy-spoke GCP_PROJECT=my-spoke-project
```

### Unified Terraform (Optional)

For customers who prefer Terraform across all clouds:

```bash
# AWS via Terraform
make tf-init TF_CLOUD=aws
make tf-apply TF_CLOUD=aws

# Azure via Terraform
make tf-init TF_CLOUD=azure
make tf-apply TF_CLOUD=azure

# GCP via Terraform
make tf-init TF_CLOUD=gcp
make tf-apply TF_CLOUD=gcp
```

## Scanning

### AWS

```bash
# Single instance
make aws-scan-instance INSTANCE_ID=i-xxx

# All tagged instances
make aws-scan-fleet
```

### Azure / GCP

Scans are triggered automatically via:
- New VM creation events
- Daily scheduled scans (2 AM UTC)

## VM Tagging

Tag VMs to control scanning behavior:

| Cloud | Tag Key | Include Value | Exclude Value |
|-------|---------|---------------|---------------|
| AWS | QualysScan | enabled | disabled |
| Azure | QualysScan | enabled | disabled |
| GCP | qualys-scan | enabled | disabled |

## QScanner Binary

The qscanner binary is automatically downloaded on first scan:
- Source: GitHub releases
- Cached locally (30-day refresh)
- SHA256 verified on each download

## Cleanup

```bash
# AWS
make aws-delete-spoke
make aws-delete-stackset OU_IDS=ou-xxxx
make aws-delete-hub
make aws-delete-secret

# Azure
make azure-delete-spoke
make azure-delete-hub

# GCP
make gcp-delete-spoke
make gcp-delete-hub

# Full cleanup
make clean-all
```

## Components by Cloud

### AWS
| Component | Hub | Spoke |
|-----------|-----|-------|
| S3 Bucket | Scan results | - |
| Secrets Manager | Qualys credentials | - |
| Step Functions | - | Orchestration |
| Lambda (3) | - | Trigger, Check, Send |
| SSM Document | - | Scan execution |
| EventBridge | - | EC2 + scheduled triggers |
| IAM Roles | - | Lambda, EC2 |

### Azure
| Component | Hub | Spoke |
|-----------|-----|-------|
| Storage Account | Scan results | - |
| Key Vault | Qualys credentials | - |
| Functions | - | Orchestration |
| Automation Account | - | Run Command execution |
| Event Grid | - | VM creation trigger |
| Managed Identity | - | Cross-resource access |

### GCP
| Component | Hub | Spoke |
|-----------|-----|-------|
| Cloud Storage | Scan results | - |
| Secret Manager | Qualys credentials | - |
| Cloud Functions | - | Orchestration |
| Pub/Sub | - | Event messaging |
| Cloud Scheduler | - | Daily trigger |
| Service Account | - | Cross-project access |
