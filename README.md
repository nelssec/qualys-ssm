# Qualys SSM Scanner

Automated vulnerability scanning for EC2 instances using AWS Systems Manager and Qualys QScanner.

## Architecture

```
EventBridge (New EC2 / Schedule)
         │
         ▼
    Lambda Trigger
         │
         ▼
    SSM Run Command
         │
         ▼
   EC2 Instances (qscanner rootfs /)
         │
         ├──► Qualys Dashboard (vulnerability results)
         └──► S3 Bucket (scan artifacts)
```

## Components

| Component | Description |
|-----------|-------------|
| `ssm-documents/` | SSM Command documents for scanning |
| `lambda/` | Trigger Lambda function |
| `cloudformation/` | Infrastructure as Code |
| `scripts/` | Helper scripts for deployment |

## Prerequisites

1. Qualys subscription with Container Security
2. Qualys API credentials stored in Secrets Manager
3. EC2 instances with SSM Agent installed
4. IAM roles for EC2 and Lambda

## Quick Start

```bash
# 1. Store Qualys credentials (if not already done)
aws secretsmanager create-secret \
  --name qualys/qscanner-token \
  --secret-string '{"access_token":"YOUR_TOKEN","pod":"US2"}'

# 2. Deploy CloudFormation stack
make deploy

# 3. Test with a specific instance
make scan-instance INSTANCE_ID=i-0abc123

# 4. Scan all tagged instances
make scan-fleet
```

## Scan Types

- `os` - Operating system package vulnerabilities
- `sca` - Software Composition Analysis (JARs, Node modules, etc.)
- `fileinsight` - File metadata and configuration analysis

## Configuration

Environment variables for Lambda:

| Variable | Default | Description |
|----------|---------|-------------|
| `QUALYS_POD` | `US2` | Qualys platform identifier |
| `SCAN_TYPES` | `os,sca,fileinsight` | Scan types to perform |
| `S3_BUCKET` | (from CFN) | Results bucket |
| `SECRET_NAME` | `qualys/qscanner-token` | Secrets Manager secret |

## Triggers

1. **New EC2 Instance** - Automatically scans when instance enters `running` state
2. **Scheduled** - Daily fleet-wide scan (configurable)
3. **Manual** - On-demand via Lambda invocation or SSM console

## Tagging

Tag EC2 instances to control scanning:

| Tag | Value | Effect |
|-----|-------|--------|
| `QualysScan` | `enabled` | Include in scheduled scans |
| `QualysScan` | `disabled` | Exclude from all scans |
