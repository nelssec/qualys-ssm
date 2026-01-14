# Qualys SSM Scanner

Automated EC2 vulnerability scanning using Qualys QScanner and AWS Systems Manager.

## Architecture

```
EventBridge ──► Lambda ──► SSM Run Command ──► EC2 (qscanner rootfs /)
    │                                              │
    │                                              ▼
    │                                         Qualys API
    │                                              │
    └──────────────────────────────────────────────┴──► S3 (results)
```

## Deploy

```bash
QUALYS_TOKEN=your-token make deploy
```

## Post-Deploy: Upload QScanner

```bash
aws s3 cp qscanner-linux-amd64 s3://BUCKET/qscanner/
aws s3 cp qscanner-linux-arm64 s3://BUCKET/qscanner/
```

## Scan

```bash
# Single instance
INSTANCE_ID=i-xxx make scan-instance

# All tagged instances (QualysScan=enabled)
make scan-fleet
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| QualysAccessToken | - | Qualys API token |
| QualysPod | US2 | Qualys platform |
| ScanTypes | os,sca,fileinsight | Scan types |
| EnableNewEC2Trigger | true | Auto-scan new instances |
| EnableScheduledScan | true | Daily fleet scan |
| ScheduleExpression | cron(0 2 * * ? *) | Schedule |

## Tagging

- `QualysScan=enabled` - Include in fleet scans
- `QualysScan=disabled` - Exclude from all scans
