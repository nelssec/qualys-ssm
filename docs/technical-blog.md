# Multi-Cloud VM Vulnerability Scanning with Qualys QScanner

## The Problem

Your security team needs vulnerability data across all cloud VMs. Traditional approaches require:

- Installing agents on every VM
- Managing agent versions across AWS, Azure, and GCP
- Hoping nothing falls through the cracks

**This solution**: Deploy once per cloud, scan automatically, get results in Qualys.

## How It Works

```mermaid
flowchart LR
    subgraph Hub["Hub Account"]
        S[("Scan Results")]
        C[("Credentials")]
    end

    subgraph Spoke["Spoke Accounts"]
        E["Event Trigger"]
        O["Orchestrator"]
        VM["VM + QScanner"]
    end

    E -->|"VM Created"| O
    O -->|"Run Scan"| VM
    VM -->|"Get Token"| C
    VM -->|"Upload Results"| S
    S -->|"Vulnerabilities"| Q["Qualys Dashboard"]
```

## Cloud-Native Implementation

Each cloud uses its native services - no third-party tools required.

```mermaid
flowchart TB
    subgraph AWS
        EB["EventBridge"] --> SF["Step Functions"]
        SF --> SSM["SSM Run Command"]
        SSM --> EC2["EC2"]
    end

    subgraph Azure
        EG["Event Grid"] --> AF["Azure Functions"]
        AF --> AA["Automation Account"]
        AA --> AVM["VM"]
    end

    subgraph GCP
        AL["Audit Logs"] --> PS["Pub/Sub"]
        PS --> CF["Cloud Functions"]
        CF --> GCE["Compute Engine"]
    end
```

## What You Get

QScanner performs three scan types in a single pass:

```mermaid
flowchart LR
    QS["QScanner"] --> OS["OS Packages<br/>CVE-2024-1234..."]
    QS --> SCA["Software Composition<br/>Log4j, OpenSSL..."]
    QS --> FI["File Insights<br/>Configs, Permissions"]

    OS --> R["Results"]
    SCA --> R
    FI --> R
    R --> QD["Qualys Dashboard"]
```

| Scan Type | What It Finds | Example |
|-----------|---------------|---------|
| **OS** | Package vulnerabilities | CVE-2024-1234 in openssl-1.1.1 |
| **SCA** | Library vulnerabilities | Log4Shell in log4j-2.14.0.jar |
| **FileInsight** | Misconfigurations | World-readable /etc/shadow |

## Deployment Flow

### 1. Deploy Hub (Once)

Central account stores credentials and collects results.

```mermaid
flowchart LR
    subgraph Hub
        SM["Secrets Manager<br/>Key Vault<br/>Secret Manager"]
        S3["S3 / Blob Storage<br/>Cloud Storage"]
    end

    Admin["Security Admin"] -->|"Deploy Hub"| Hub
    Admin -->|"Add Qualys Token"| SM
```

### 2. Deploy Spokes (Per Account)

Lightweight deployment triggers scans and reports back.

```mermaid
flowchart LR
    subgraph Spoke1["Account A"]
        T1["Trigger"] --> V1["VMs"]
    end

    subgraph Spoke2["Account B"]
        T2["Trigger"] --> V2["VMs"]
    end

    subgraph Spoke3["Account C"]
        T3["Trigger"] --> V3["VMs"]
    end

    V1 --> Hub["Hub"]
    V2 --> Hub
    V3 --> Hub
    Hub --> Qualys["Qualys"]
```

## Scan Triggers

Two automatic triggers ensure coverage:

```mermaid
flowchart TB
    subgraph Triggers
        NEW["New VM Created"] -->|"Immediate"| SCAN["Scan"]
        SCHED["Daily Schedule<br/>2 AM UTC"] -->|"Fleet Scan"| SCAN
    end

    SCAN --> RESULTS["Results in Qualys"]
```

---

## End-to-End: AWS

### Architecture Deep Dive

```mermaid
flowchart TB
    subgraph EventBridge["Amazon EventBridge"]
        EC2Event["EC2 State Change Rule"]
        SchedEvent["Scheduled Rule<br/>cron(0 2 * * ? *)"]
    end

    subgraph Lambda["AWS Lambda"]
        Trigger["qualys-ssm-trigger<br/>Python 3.12"]
        Check["qualys-ssm-check<br/>Python 3.12"]
        Send["qualys-ssm-send<br/>Python 3.12"]
    end

    subgraph StepFunctions["AWS Step Functions"]
        SM["qualys-ssm-scan<br/>State Machine"]
    end

    subgraph SSM["AWS Systems Manager"]
        Doc["SSM Document<br/>qualys-ssm-scan"]
    end

    subgraph EC2["Amazon EC2"]
        Instance["Target Instance<br/>SSM Agent"]
    end

    subgraph Hub["Hub Account"]
        Secrets["Secrets Manager<br/>qualys-ssm-scanner-credentials"]
        S3["S3 Bucket<br/>qualys-ssm-hub-{AccountId}"]
    end

    EC2Event -->|"instance running"| Trigger
    SchedEvent -->|"daily 2 AM"| Trigger
    Trigger -->|"StartExecution"| SM
    SM -->|"CheckSSM"| Check
    Check -->|"DescribeInstanceInformation"| SSM
    SM -->|"SendCommand"| Send
    Send -->|"SendCommand"| Doc
    Doc -->|"runShellScript"| Instance
    Instance -->|"GetSecretValue"| Secrets
    Instance -->|"PutObject"| S3
```

### Sequence Diagram

```mermaid
sequenceDiagram
    autonumber
    participant EC2 as EC2 Instance
    participant EB as EventBridge
    participant TL as Trigger Lambda
    participant SF as Step Functions
    participant CL as Check Lambda
    participant SSM as SSM Agent
    participant SL as Send Lambda
    participant SM as Secrets Manager
    participant S3 as S3 Bucket
    participant Q as Qualys API

    Note over EC2,EB: VM Launch Event
    EC2->>EB: State = "running"
    EB->>TL: EC2 State Change Event
    TL->>TL: Parse instance ID
    TL->>SF: StartExecution({instance_ids: [i-xxx]})

    Note over SF,SSM: SSM Agent Readiness Check
    SF->>CL: CheckSSM state
    CL->>SSM: DescribeInstanceInformation
    SSM-->>CL: PingStatus: "Online"
    CL-->>SF: {ready: [i-xxx], not_ready: []}

    Note over SF,SL: Execute Scan Command
    SF->>SL: SendCommand state
    SL->>SSM: SendCommand(DocumentName: qualys-ssm-scan)
    SSM->>EC2: Execute runShellScript

    Note over EC2,Q: Scan Execution
    EC2->>EC2: Download QScanner binary
    EC2->>EC2: Verify SHA256 checksum
    EC2->>SM: GetSecretValue(qualys-ssm-scanner-credentials)
    SM-->>EC2: {qualys_pod, qualys_access_token}
    EC2->>EC2: Run: qscanner --scan-types os,sca,fileinsight rootfs /
    EC2->>Q: Report vulnerabilities
    EC2->>S3: Upload JSON + SARIF results
    S3-->>EC2: 200 OK

    Note over SF: Scan Complete
    SSM-->>SL: CommandStatus: "Success"
    SL-->>SF: {status: "started", commandId: "xxx"}
```

### Key AWS Resources

| Resource | Type | Purpose |
|----------|------|---------|
| `qualys-ssm-trigger` | Lambda Function | Parses events, starts Step Function |
| `qualys-ssm-check` | Lambda Function | Polls SSM agent readiness |
| `qualys-ssm-send` | Lambda Function | Invokes SSM Run Command |
| `qualys-ssm-scan` | Step Function | Orchestrates check → wait → send flow |
| `qualys-ssm-scan` | SSM Document | Shell script for QScanner execution |
| `qualys-ssm-new-ec2` | EventBridge Rule | Triggers on EC2 running state |
| `qualys-ssm-scheduled` | EventBridge Rule | Daily fleet scan at 2 AM UTC |

### SSM Document Execution

The SSM Document runs this workflow on the EC2 instance:

```mermaid
flowchart TB
    A["Start"] --> B["Get Instance Metadata<br/>IMDSv2 Token"]
    B --> C["Detect Architecture<br/>x86_64 / arm64"]
    C --> D{"QScanner<br/>Cached?"}
    D -->|"No"| E["Download from GitHub"]
    D -->|"Yes, > 30 days"| F["Check SHA256"]
    F -->|"Changed"| E
    F -->|"Same"| G["Use Cached"]
    D -->|"Yes, < 30 days"| G
    E --> H["Verify SHA256"]
    H --> G
    G --> I["Get Qualys Token<br/>from Secrets Manager"]
    I --> J["Run QScanner<br/>--scan-types os,sca,fileinsight"]
    J --> K["Upload Results to S3<br/>scans/{AccountId}/{InstanceId}/{Timestamp}/"]
    K --> L["Cleanup temp files"]
    L --> M["End"]
```

---

## End-to-End: Azure

### Architecture Deep Dive

```mermaid
flowchart TB
    subgraph EventGrid["Azure Event Grid"]
        Topic["System Topic<br/>Microsoft.Resources.Subscriptions"]
        Sub["Event Subscription<br/>ResourceWriteSuccess filter"]
    end

    subgraph Functions["Azure Functions"]
        Trigger["TriggerScan<br/>Python 3.12"]
        Orchestrator["ScanOrchestrator<br/>Durable Function"]
    end

    subgraph Automation["Azure Automation"]
        Account["Automation Account"]
        Runbook["Invoke-QualysScan<br/>PowerShell Runbook"]
    end

    subgraph Compute["Azure Compute"]
        VM["Target VM<br/>Run Command"]
    end

    subgraph Hub["Hub Resources"]
        KeyVault["Key Vault<br/>qualys-hub-{suffix}"]
        Storage["Storage Account<br/>qualysscan{suffix}"]
    end

    Topic -->|"VM created"| Sub
    Sub -->|"HTTP trigger"| Trigger
    Trigger -->|"Start orchestration"| Orchestrator
    Orchestrator -->|"Start runbook"| Account
    Account -->|"Invoke-AzVMRunCommand"| Runbook
    Runbook -->|"Run Command"| VM
    VM -->|"Get-AzKeyVaultSecret"| KeyVault
    VM -->|"Upload blob"| Storage
```

### Sequence Diagram

```mermaid
sequenceDiagram
    autonumber
    participant VM as Azure VM
    participant ARM as Azure Resource Manager
    participant EG as Event Grid
    participant AF as Azure Function
    participant AA as Automation Account
    participant RB as Runbook
    participant KV as Key Vault
    participant SA as Storage Account
    participant Q as Qualys API

    Note over VM,ARM: VM Creation Event
    VM->>ARM: Create VM Request
    ARM->>ARM: Provision VM
    ARM->>EG: ResourceWriteSuccess Event

    Note over EG,AF: Event Processing
    EG->>AF: HTTP Trigger (VM Created)
    AF->>AF: Validate VM (check tags)
    AF->>AF: Extract resourceId, subscriptionId

    Note over AF,RB: Scan Orchestration
    AF->>AA: Start-AzAutomationRunbook
    AA->>RB: Execute Invoke-QualysScan
    RB->>RB: Get VM details from resourceId

    Note over RB,VM: Run Command Execution
    RB->>VM: Invoke-AzVMRunCommand -ScriptPath scan.sh

    Note over VM,Q: Scan Execution
    VM->>VM: Download QScanner binary
    VM->>VM: Verify SHA256 checksum
    VM->>KV: Get-AzKeyVaultSecret -Name qualys-access-token
    KV-->>VM: SecretValue
    VM->>KV: Get-AzKeyVaultSecret -Name qualys-pod
    KV-->>VM: SecretValue
    VM->>VM: Run: qscanner --scan-types os,sca,fileinsight rootfs /
    VM->>Q: Report vulnerabilities
    VM->>SA: Upload to scans/{subscriptionId}/{vmName}/{timestamp}/
    SA-->>VM: 201 Created

    Note over RB: Scan Complete
    VM-->>RB: Exit Code 0
    RB-->>AA: Runbook Completed
    AA-->>AF: Job Status: Completed
```

### Key Azure Resources

| Resource | Type | Purpose |
|----------|------|---------|
| `qualys-scan-{suffix}` | Function App | Serverless compute, Python 3.12 |
| `TriggerScan` | Function | HTTP trigger from Event Grid |
| `qualys-automation-{suffix}` | Automation Account | Hosts runbooks for VM execution |
| `Invoke-QualysScan` | Runbook | PowerShell script invoking Run Command |
| `qualys-vm-events-{suffix}` | Event Grid System Topic | Captures subscription-level events |
| `new-vm-trigger` | Event Subscription | Filters for VM creation events |
| `qualys-hub-{suffix}` | Key Vault | Stores Qualys credentials |
| `qualysscan{suffix}` | Storage Account | Blob storage for scan results |

### Event Grid Filter

The Event Grid subscription filters for VM creation:

```json
{
  "includedEventTypes": ["Microsoft.Resources.ResourceWriteSuccess"],
  "advancedFilters": [
    {
      "key": "data.resourceProvider",
      "operatorType": "StringEquals",
      "values": ["Microsoft.Compute"]
    },
    {
      "key": "data.operationName",
      "operatorType": "StringContains",
      "values": ["Microsoft.Compute/virtualMachines/write"]
    }
  ]
}
```

### Managed Identity Flow

```mermaid
flowchart LR
    subgraph Spoke["Spoke Subscription"]
        FA["Function App<br/>System-Assigned Identity"]
        AA["Automation Account<br/>System-Assigned Identity"]
    end

    subgraph Hub["Hub Subscription"]
        KV["Key Vault"]
        SA["Storage Account"]
    end

    FA -->|"Key Vault Secrets User"| KV
    FA -->|"Virtual Machine Contributor"| VM["Target VMs"]
    AA -->|"Virtual Machine Contributor"| VM
    AA -->|"Storage Blob Data Contributor"| SA
```

---

## End-to-End: GCP

### Architecture Deep Dive

```mermaid
flowchart TB
    subgraph Logging["Cloud Logging"]
        AuditLog["Audit Log<br/>compute.instances.insert"]
        Sink["Log Sink<br/>qualys-new-vm-trigger"]
    end

    subgraph Messaging["Cloud Pub/Sub"]
        Topic["Topic<br/>qualys-scan-trigger"]
        Subscription["Subscription<br/>qualys-scan-trigger-sub"]
    end

    subgraph Functions["Cloud Functions Gen2"]
        Scanner["qualys-vm-scanner<br/>Python 3.12"]
    end

    subgraph Scheduler["Cloud Scheduler"]
        Job["qualys-daily-scan<br/>cron: 0 2 * * *"]
    end

    subgraph Compute["Compute Engine"]
        VM["Target VM<br/>Startup Script / OS Config"]
    end

    subgraph Hub["Hub Project"]
        SecretMgr["Secret Manager<br/>qualys-ssm-scanner-credentials"]
        GCS["Cloud Storage<br/>qualys-ssm-hub-{project}"]
    end

    AuditLog -->|"instances.insert"| Sink
    Sink -->|"Publish"| Topic
    Job -->|"Publish"| Topic
    Topic --> Subscription
    Subscription -->|"Push"| Scanner
    Scanner -->|"gcloud compute ssh"| VM
    VM -->|"Access secret"| SecretMgr
    VM -->|"Upload objects"| GCS
```

### Sequence Diagram

```mermaid
sequenceDiagram
    autonumber
    participant GCE as Compute Engine
    participant AL as Audit Logs
    participant LS as Log Sink
    participant PS as Pub/Sub Topic
    participant CF as Cloud Function
    participant SM as Secret Manager
    participant GCS as Cloud Storage
    participant Q as Qualys API

    Note over GCE,AL: VM Creation Event
    GCE->>GCE: Create Instance
    GCE->>AL: AuditLog: compute.instances.insert
    AL->>LS: Match filter: methodName="v1.compute.instances.insert"
    LS->>PS: Publish message

    Note over PS,CF: Event Processing
    PS->>CF: Trigger (Pub/Sub push)
    CF->>CF: Parse instance name, zone, project
    CF->>CF: Check labels (qualys-scan != disabled)

    Note over CF,GCE: Scan Execution via Metadata
    CF->>GCE: Set startup-script metadata
    GCE->>GCE: Execute startup script on next boot

    Note over GCE,Q: Alternative: Direct SSH Execution
    CF->>GCE: gcloud compute ssh --command="scan.sh"

    Note over GCE,Q: Scan Execution
    GCE->>GCE: Download QScanner binary
    GCE->>GCE: Verify SHA256 checksum
    GCE->>SM: gcloud secrets versions access latest --secret=qualys-ssm-scanner-credentials
    SM-->>GCE: {"qualys_pod": "US2", "qualys_access_token": "xxx"}
    GCE->>GCE: Run: qscanner --scan-types os,sca,fileinsight rootfs /
    GCE->>Q: Report vulnerabilities
    GCE->>GCS: gsutil cp results gs://qualys-ssm-hub-{project}/scans/{project}/{instance}/{timestamp}/
    GCS-->>GCE: Upload complete

    Note over CF: Scan Complete
    GCE-->>CF: Exit Code 0
```

### Key GCP Resources

| Resource | Type | Purpose |
|----------|------|---------|
| `qualys-vm-scanner` | Cloud Function Gen2 | Serverless compute, Python 3.12 |
| `qualys-scan-trigger` | Pub/Sub Topic | Event messaging |
| `qualys-scan-trigger-sub` | Pub/Sub Subscription | Delivers messages to function |
| `qualys-new-vm-trigger` | Log Sink | Routes audit logs to Pub/Sub |
| `qualys-daily-scan` | Cloud Scheduler Job | Daily fleet scan at 2 AM UTC |
| `qualys-scanner` | Service Account | Cross-project access |
| `qualys-ssm-scanner-credentials` | Secret Manager Secret | Stores Qualys credentials |
| `qualys-ssm-hub-{project}` | Cloud Storage Bucket | Stores scan results |

### Log Sink Filter

The log sink captures VM creation events:

```
resource.type="gce_instance"
protoPayload.methodName="v1.compute.instances.insert"
protoPayload.response.status="RUNNING"
```

### Service Account Permissions

```mermaid
flowchart LR
    subgraph Spoke["Spoke Project"]
        SA["qualys-scanner<br/>Service Account"]
    end

    subgraph Hub["Hub Project"]
        SM["Secret Manager"]
        GCS["Cloud Storage"]
    end

    subgraph Spoke2["Spoke Project"]
        GCE["Compute Instances"]
    end

    SA -->|"roles/secretmanager.secretAccessor"| SM
    SA -->|"roles/storage.objectCreator"| GCS
    SA -->|"roles/compute.instanceAdmin.v1"| GCE
```

### Cloud Function Environment

```python
# Environment variables set on Cloud Function
HUB_PROJECT_ID   = "security-hub-project"
HUB_BUCKET_NAME  = "qualys-ssm-hub-security-hub-project"
HUB_SECRET_ID    = "qualys-ssm-scanner-credentials"
SCAN_TYPES       = "os,sca,fileinsight"
PROJECT_ID       = "workload-project-123"
```

---

## Quick Start

**AWS:**
```bash
# Set credentials
export QUALYS_ACCESS_TOKEN="your-token"

# Deploy hub (security account)
make aws-deploy-hub ORG_ID=o-xxxxx

# Deploy spokes (org-wide via StackSet)
make aws-deploy-stackset-instances OU_IDS=ou-xxxxx
```

**Azure:**
```bash
# Set credentials
export QUALYS_ACCESS_TOKEN="your-token"

# Deploy hub
make azure-deploy-hub AZURE_RESOURCE_GROUP=qualys-hub-rg

# Deploy spoke
HUB_SUBSCRIPTION_ID=xxx \
HUB_RESOURCE_GROUP=qualys-hub-rg \
HUB_STORAGE_ACCOUNT=qualysscanxxx \
HUB_KEY_VAULT=qualys-hub-xxx \
make azure-deploy-spoke AZURE_RESOURCE_GROUP=qualys-spoke-rg
```

**GCP:**
```bash
# Set credentials
export QUALYS_ACCESS_TOKEN="your-token"

# Deploy hub
make gcp-deploy-hub GCP_PROJECT=security-hub-project

# Deploy spoke
HUB_PROJECT_ID=security-hub-project \
HUB_BUCKET_NAME=qualys-ssm-hub-security-hub-project \
HUB_SECRET_ID=qualys-ssm-scanner-credentials \
make gcp-deploy-spoke GCP_PROJECT=workload-project
```

## Results in Qualys

Within minutes of VM launch, you'll see:

- **Asset inventory** with cloud metadata (instance ID, region, account/subscription/project)
- **Vulnerability findings** mapped to CVEs with severity scores
- **Software inventory** including transitive dependencies
- **Compliance data** from file and configuration analysis

## Why This Approach

| Traditional Agent | This Solution |
|-------------------|---------------|
| Install on every VM | Deploy once per account |
| Always running | On-demand only |
| Update agents everywhere | Update hub only |
| Miss VMs without agent | Event-driven, automatic |
| Different per cloud | Same pattern everywhere |

## Security Model

```mermaid
flowchart TB
    subgraph Hub["Hub (Trusted)"]
        CREDS["Credentials<br/>Read-only from spokes"]
        RESULTS["Results<br/>Write-only from spokes"]
    end

    subgraph Spoke["Spoke (Minimal)"]
        SCAN["Scanner<br/>No stored credentials"]
    end

    Spoke -->|"Get token"| CREDS
    Spoke -->|"Upload scan"| RESULTS
```

- Credentials never stored in spoke accounts
- Spokes have minimal permissions (read creds, write results)
- All storage encrypted at rest
- TLS enforced on all API calls
- No persistent processes on VMs
- QScanner binary verified via SHA256 checksum

## Get Started

1. Clone the repo
2. Set `QUALYS_ACCESS_TOKEN`
3. Deploy hub + spokes
4. VMs scanned automatically

Questions? Open an issue.
