# Automated EC2 Vulnerability Scanning with Qualys QScanner and AWS Systems Manager

## Introduction

Traditional agent-based vulnerability scanning requires deploying and maintaining scanning agents on every EC2 instance. This approach has challenges:

- **Agent sprawl** - Another agent to install, update, and manage
- **Resource overhead** - Continuous agent processes consuming CPU/memory
- **Deployment friction** - Must bake agents into AMIs or install post-launch
- **Coverage gaps** - Instances launched without agents go unscanned

This solution takes a different approach: **agentless, on-demand scanning** using Qualys QScanner and AWS Systems Manager (SSM). Instead of persistent agents, we trigger scans via SSM Run Command when instances launch or on a schedule.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              AWS Account                                     │
│                                                                             │
│  ┌───────────────────┐                                                      │
│  │   EventBridge     │                                                      │
│  │  ┌─────────────┐  │     ┌──────────────┐     ┌─────────────────────┐   │
│  │  │ New EC2     │──┼────►│   Lambda     │────►│  SSM Run Command    │   │
│  │  │ Instance    │  │     │  (Trigger)   │     │                     │   │
│  │  └─────────────┘  │     └──────────────┘     └──────────┬──────────┘   │
│  │  ┌─────────────┐  │                                     │              │
│  │  │ Scheduled   │──┼─────────────┘                       │              │
│  │  │ (Daily)     │  │                                     ▼              │
│  │  └─────────────┘  │                          ┌─────────────────────┐   │
│  └───────────────────┘                          │   EC2 Instances     │   │
│                                                 │  ┌─────┐  ┌─────┐   │   │
│  ┌───────────────────┐                          │  │ i-1 │  │ i-2 │   │   │
│  │ Secrets Manager   │◄─────────────────────────│  │     │  │     │   │   │
│  │ (Qualys Token)    │                          │  │qscan│  │qscan│   │   │
│  └───────────────────┘                          │  └──┬──┘  └──┬──┘   │   │
│                                                 └─────┼────────┼──────┘   │
│                                                       │        │          │
│                                                       ▼        ▼          │
│  ┌───────────────────┐     ┌───────────────────────────────────────────┐ │
│  │ Qualys Dashboard  │◄────│              S3 Bucket                     │ │
│  │ (Vuln Results)    │     │         (Scan Artifacts)                  │ │
│  └───────────────────┘     └───────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

## How It Works

### 1. Event-Driven Scanning

When a new EC2 instance enters the `running` state, EventBridge captures the state change event and triggers our Lambda function:

```json
{
  "source": ["aws.ec2"],
  "detail-type": ["EC2 Instance State-change Notification"],
  "detail": {
    "state": ["running"]
  }
}
```

The Lambda function:
1. Extracts the instance ID from the event
2. Waits for the SSM agent to come online (configurable delay)
3. Sends an SSM Run Command to execute the scan

### 2. The QScanner rootfs Command

QScanner's `rootfs` command is the key to this solution. Unlike container image scanning, `rootfs` scans a live filesystem:

```bash
./qscanner --pod US2 \
  --mode get-report \
  --scan-types os,sca,fileinsight \
  --shell-commands "uname -a=$(uname -a)" \
  --exclude-dirs /proc,/sys,/dev,/run \
  rootfs /
```

**What gets scanned:**

| Scan Type | What It Finds |
|-----------|---------------|
| `os` | Operating system packages (rpm, dpkg, apk) and their CVEs |
| `sca` | Software Composition Analysis - JARs, Node modules, Python packages, Go binaries |
| `fileinsight` | File metadata, permissions, configuration analysis |

### 3. SSM Document

The SSM Document defines the scan workflow:

```yaml
mainSteps:
  - action: aws:runShellScript
    name: runQscanner
    inputs:
      runCommand:
        - |
          # Get Qualys credentials from Secrets Manager
          SECRET_JSON=$(aws secretsmanager get-secret-value \
            --secret-id "qualys/qscanner-token" \
            --query 'SecretString' --output text)
          export QUALYS_ACCESS_TOKEN=$(echo $SECRET_JSON | jq -r '.access_token')

          # Run the scan
          /opt/qualys/qscanner \
            --pod {{ Pod }} \
            --mode get-report \
            --scan-types {{ ScanTypes }} \
            --shell-commands "uname -a=$(uname -a)" \
            rootfs /

          # Upload results to S3
          aws s3 cp /tmp/results/ s3://bucket/scans/${INSTANCE_ID}/ --recursive
```

### 4. Results Flow

Scan results flow to two destinations:

1. **Qualys Dashboard** - Full vulnerability report with CVE details, QDS scores, and remediation guidance
2. **S3 Bucket** - JSON/SARIF artifacts for integration with other tools

## Deployment

### Prerequisites

1. AWS account with appropriate permissions
2. Qualys subscription with Container Security module
3. EC2 instances with SSM Agent installed (Amazon Linux 2/2023, Ubuntu 16.04+, etc. have it pre-installed)

### Step 1: Get Your Qualys Token

Generate an access token from the Qualys platform:
1. Log into Qualys
2. Navigate to **Administration** → **API Tokens**
3. Generate a new token with Container Security permissions

### Step 2: Deploy the Stack

```bash
# Clone the repository
git clone https://github.com/your-org/qualys-ssm.git
cd qualys-ssm

# Deploy (replace with your token)
QUALYS_TOKEN=your-token-here make deploy
```

### Step 3: Upload QScanner Binary

Download QScanner from Qualys and upload to the S3 bucket:

```bash
# Download from Qualys portal, then:
make upload-qscanner
```

### Step 4: Tag Instances for Scanning

For scheduled fleet scans, tag instances:

```bash
aws ec2 create-tags \
  --resources i-0abc123 \
  --tags Key=QualysScan,Value=enabled
```

## Scanning Options

### On-Demand: Specific Instance

```bash
INSTANCE_ID=i-0abc123 make scan-instance
```

### On-Demand: All Tagged Instances

```bash
make scan-fleet
```

### Automatic: New Instances

Enabled by default - any new EC2 instance is scanned when it starts.

### Scheduled: Daily Fleet Scan

Enabled by default - runs daily at 2 AM UTC. Customize the schedule:

```yaml
ScheduleExpression: 'cron(0 2 * * ? *)'  # Daily at 2 AM UTC
```

## Use Cases

### 1. Golden AMI Validation

Scan your base AMIs before deployment:

```bash
# Launch instance from AMI
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id ami-xxxxx \
  --instance-type t3.micro \
  --query 'Instances[0].InstanceId' \
  --output text)

# Wait for scan to complete, check results
make get-scan-results INSTANCE_ID=$INSTANCE_ID
```

### 2. Compliance Auditing

Schedule weekly scans and export to your SIEM:

```bash
# Results are stored in S3 in SARIF format
aws s3 sync s3://qualys-ssm-results-xxx/scans/ ./local-scans/
# Import SARIF files into your security tooling
```

### 3. Incident Response

Quickly scan a potentially compromised instance:

```bash
INSTANCE_ID=i-suspicious make scan-instance
```

### 4. CI/CD Pipeline Integration

Trigger scans after deployment:

```yaml
# GitHub Actions example
- name: Scan deployed instance
  run: |
    aws lambda invoke \
      --function-name QualysSSMScanner-Trigger \
      --payload '{"instance_ids":["${{ env.INSTANCE_ID }}"]}' \
      response.json
```

## Advantages Over Agent-Based Scanning

| Aspect | Agent-Based | SSM-Based (This Solution) |
|--------|-------------|---------------------------|
| **Installation** | Required on every instance | None - uses SSM agent (pre-installed) |
| **Maintenance** | Agent updates needed | QScanner binary in S3, one location |
| **Resource Usage** | Continuous | On-demand only |
| **Coverage** | Only where agents installed | Any SSM-managed instance |
| **Scan Control** | Agent schedules | Centralized Lambda control |
| **Cost** | Agent licensing | Pay-per-scan (API calls) |

## Security Considerations

### Secrets Management

Qualys credentials are stored in AWS Secrets Manager, never in code or environment variables:

```python
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "qualys/qscanner-token")
```

### IAM Least Privilege

EC2 instances only get permissions they need:
- `secretsmanager:GetSecretValue` - Only for the Qualys secret
- `s3:PutObject` - Only to the results bucket
- SSM permissions via `AmazonSSMManagedInstanceCore`

### Network Security

QScanner communicates with:
- Qualys API endpoints (outbound HTTPS)
- S3 (can use VPC endpoint for private access)
- Secrets Manager (can use VPC endpoint)

## Troubleshooting

### SSM Agent Not Ready

If scans fail with "No SSM-ready instances":

```bash
# Check SSM agent status
make check-ssm-status

# Verify instance has SSM role attached
aws ec2 describe-iam-instance-profile-associations \
  --filters Name=instance-id,Values=i-xxxxx
```

### QScanner Binary Not Found

Ensure the binary is uploaded to S3:

```bash
# Upload the binary
make upload-qscanner

# Verify it's there
aws s3 ls s3://qualys-ssm-results-xxx/qscanner/
```

### Scan Timeout

For large instances with many packages, increase the timeout in the SSM document:

```yaml
timeoutSeconds: '1800'  # 30 minutes
```

## Cost Optimization

- **SSM Run Command** - Free for on-demand use
- **Lambda** - Minimal cost (~$0.20/million invocations)
- **S3** - Results lifecycle policy auto-deletes after 90 days
- **Secrets Manager** - ~$0.40/month per secret

## Conclusion

This SSM-based approach provides comprehensive vulnerability scanning without the overhead of traditional agents. By leveraging QScanner's `rootfs` capability and AWS Systems Manager, you get:

- **Immediate coverage** for new instances
- **Centralized control** over scan scheduling and targeting
- **No agent maintenance** burden
- **Full visibility** into OS and application-level vulnerabilities

The solution scales from a single instance to thousands, with EventBridge and SSM handling the orchestration automatically.

## Resources

- [QScanner Documentation](https://www.qualys.com/docs/qscanner/)
- [AWS Systems Manager Run Command](https://docs.aws.amazon.com/systems-manager/latest/userguide/execute-remote-commands.html)
- [EventBridge EC2 Events](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/monitoring-instance-state-changes.html)
