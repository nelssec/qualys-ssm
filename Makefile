# Qualys VM Scanner - Multi-Cloud Makefile
# Supports AWS (CloudFormation), Azure (Bicep), GCP (Terraform), and unified Terraform

# =============================================================================
# COMMON VARIABLES
# =============================================================================

QUALYS_POD ?= US2
QUALYS_ACCESS_TOKEN ?= $(shell echo $$QUALYS_ACCESS_TOKEN)

# =============================================================================
# AWS VARIABLES
# =============================================================================

AWS_REGION ?= us-east-1
AWS_STACK_NAME ?= qualys-ssm-scanner

# =============================================================================
# AZURE VARIABLES
# =============================================================================

AZURE_RESOURCE_GROUP ?= qualys-scanner-rg
AZURE_LOCATION ?= eastus

# =============================================================================
# GCP VARIABLES
# =============================================================================

GCP_PROJECT ?= $(shell gcloud config get-value project 2>/dev/null)
GCP_REGION ?= us-central1

# =============================================================================
# TERRAFORM VARIABLES
# =============================================================================

TF_CLOUD ?= aws
TF_DIR ?= terraform/modules/$(TF_CLOUD)

# =============================================================================
# PHONY TARGETS
# =============================================================================

.PHONY: help \
	aws-validate aws-create-secret aws-deploy-hub aws-deploy-spoke \
	aws-deploy-stackset aws-deploy-stackset-instances \
	aws-delete-hub aws-delete-spoke aws-delete-stackset aws-delete-secret \
	aws-status-hub aws-status-spoke aws-scan-instance aws-scan-fleet \
	azure-deploy-hub azure-deploy-spoke azure-delete-hub azure-delete-spoke \
	gcp-deploy-hub gcp-deploy-spoke gcp-delete-hub gcp-delete-spoke \
	tf-init tf-plan tf-apply tf-destroy \
	clean

# =============================================================================
# HELP
# =============================================================================

help:
	@echo "Qualys VM Scanner - Multi-Cloud"
	@echo ""
	@echo "Authentication:"
	@echo "  export QUALYS_ACCESS_TOKEN=...   Qualys access token (required)"
	@echo "  QUALYS_POD=US2                   Qualys POD (default: US2)"
	@echo ""
	@echo "═══════════════════════════════════════════════════════════════════"
	@echo "AWS (CloudFormation)"
	@echo "═══════════════════════════════════════════════════════════════════"
	@echo "  make aws-deploy-hub              Deploy hub (S3 + Secrets Manager)"
	@echo "  make aws-deploy-spoke            Deploy spoke to current account"
	@echo "  make aws-deploy-stackset         Create StackSet for org deployment"
	@echo "  make aws-deploy-stackset-instances  Deploy StackSet to OUs"
	@echo "  make aws-status-hub              Show hub stack outputs"
	@echo "  make aws-status-spoke            Show spoke stack outputs"
	@echo "  make aws-scan-instance           Scan single instance"
	@echo "  make aws-scan-fleet              Scan all tagged instances"
	@echo "  make aws-delete-hub              Delete hub stack"
	@echo "  make aws-delete-spoke            Delete spoke stack"
	@echo ""
	@echo "  Variables:"
	@echo "    AWS_REGION=us-east-1           AWS region"
	@echo "    ORG_ID=o-xxx                   AWS Organization ID (for hub)"
	@echo "    OU_IDS=ou-xxx                  Comma-separated OU IDs (StackSet)"
	@echo "    HUB_ACCOUNT_ID=123...          Hub account ID (for spoke)"
	@echo "    HUB_BUCKET=qualys-ssm-hub-...  Hub S3 bucket name (for spoke)"
	@echo ""
	@echo "═══════════════════════════════════════════════════════════════════"
	@echo "Azure (Bicep)"
	@echo "═══════════════════════════════════════════════════════════════════"
	@echo "  make azure-deploy-hub            Deploy hub (Storage + Key Vault)"
	@echo "  make azure-deploy-spoke          Deploy spoke resources"
	@echo "  make azure-delete-hub            Delete hub resources"
	@echo "  make azure-delete-spoke          Delete spoke resources"
	@echo ""
	@echo "  Variables:"
	@echo "    AZURE_RESOURCE_GROUP           Resource group name"
	@echo "    AZURE_LOCATION=eastus          Azure region"
	@echo "    HUB_SUBSCRIPTION_ID            Hub subscription (for spoke)"
	@echo ""
	@echo "═══════════════════════════════════════════════════════════════════"
	@echo "GCP (Terraform)"
	@echo "═══════════════════════════════════════════════════════════════════"
	@echo "  make gcp-deploy-hub              Deploy hub (GCS + Secret Manager)"
	@echo "  make gcp-deploy-spoke            Deploy spoke resources"
	@echo "  make gcp-delete-hub              Delete hub resources"
	@echo "  make gcp-delete-spoke            Delete spoke resources"
	@echo ""
	@echo "  Variables:"
	@echo "    GCP_PROJECT                    GCP project ID"
	@echo "    GCP_REGION=us-central1         GCP region"
	@echo "    HUB_PROJECT_ID                 Hub project (for spoke)"
	@echo ""
	@echo "═══════════════════════════════════════════════════════════════════"
	@echo "Terraform (Unified)"
	@echo "═══════════════════════════════════════════════════════════════════"
	@echo "  make tf-init TF_CLOUD=aws        Initialize Terraform for cloud"
	@echo "  make tf-plan TF_CLOUD=aws        Plan deployment"
	@echo "  make tf-apply TF_CLOUD=aws       Apply deployment"
	@echo "  make tf-destroy TF_CLOUD=aws     Destroy deployment"
	@echo ""
	@echo "  TF_CLOUD options: aws, azure, gcp"
	@echo ""

# =============================================================================
# AWS CLOUDFORMATION
# =============================================================================

aws-validate:
	@aws cloudformation validate-template --template-body file://aws/cloudformation/hub.yaml --region $(AWS_REGION) > /dev/null
	@aws cloudformation validate-template --template-body file://aws/cloudformation/spoke.yaml --region $(AWS_REGION) > /dev/null
	@echo "Templates validated"

aws-create-secret:
	@if [ -z "$(QUALYS_ACCESS_TOKEN)" ]; then \
		echo "Error: QUALYS_ACCESS_TOKEN not set"; \
		exit 1; \
	fi
	@mkdir -p build
	@SECRET_JSON='{"qualys_pod":"$(QUALYS_POD)","qualys_access_token":"$(QUALYS_ACCESS_TOKEN)"}'; \
	SECRET_ARN=$$(aws secretsmanager create-secret \
		--name "$(AWS_STACK_NAME)-credentials" \
		--description "Qualys credentials for SSM scanner" \
		--secret-string "$$SECRET_JSON" \
		--region $(AWS_REGION) \
		--query ARN \
		--output text 2>/dev/null || \
		aws secretsmanager describe-secret \
		--secret-id "$(AWS_STACK_NAME)-credentials" \
		--region $(AWS_REGION) \
		--query ARN \
		--output text); \
	echo $$SECRET_ARN > build/secret-arn.txt
	@echo "Secret ARN: $$(cat build/secret-arn.txt)"

aws-deploy-hub: aws-validate aws-create-secret
	@if [ -z "$(ORG_ID)" ]; then \
		echo "Error: ORG_ID not set"; \
		echo "Usage: make aws-deploy-hub ORG_ID=o-xxxxxxxxxx"; \
		exit 1; \
	fi
	@ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text); \
	aws cloudformation deploy \
		--stack-name $(AWS_STACK_NAME)-hub \
		--template-file aws/cloudformation/hub.yaml \
		--parameter-overrides \
			OrganizationId=$(ORG_ID) \
			SecretArn=$$(cat build/secret-arn.txt) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION)
	@echo ""
	@echo "Hub deployed. Outputs:"
	@$(MAKE) aws-status-hub
	@echo ""
	@echo "Next: Deploy spokes with 'make aws-deploy-stackset-instances OU_IDS=ou-xxxx'"

aws-deploy-spoke:
	@if [ -z "$(HUB_ACCOUNT_ID)" ]; then \
		echo "Error: HUB_ACCOUNT_ID not set"; \
		exit 1; \
	fi
	@if [ -z "$(HUB_BUCKET)" ]; then \
		echo "Error: HUB_BUCKET not set"; \
		exit 1; \
	fi
	@SECRET_ARN=$$(cat build/secret-arn.txt 2>/dev/null || echo ""); \
	if [ -z "$$SECRET_ARN" ]; then \
		echo "Error: Secret not found. Run 'make aws-deploy-hub' first or set HUB_SECRET_ARN"; \
		exit 1; \
	fi; \
	aws cloudformation deploy \
		--stack-name $(AWS_STACK_NAME)-spoke \
		--template-file aws/cloudformation/spoke.yaml \
		--parameter-overrides \
			HubAccountId=$(HUB_ACCOUNT_ID) \
			HubBucketName=$(HUB_BUCKET) \
			HubSecretArn=$$SECRET_ARN \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION)
	@echo "Spoke deployed"

aws-deploy-stackset:
	@if [ -z "$(HUB_ACCOUNT_ID)" ]; then \
		echo "Error: HUB_ACCOUNT_ID not set"; \
		exit 1; \
	fi
	@if [ -z "$(HUB_BUCKET)" ]; then \
		echo "Error: HUB_BUCKET not set"; \
		exit 1; \
	fi
	@SECRET_ARN=$$(cat build/secret-arn.txt 2>/dev/null || echo ""); \
	if [ -z "$$SECRET_ARN" ]; then \
		echo "Error: Secret not found. Run 'make aws-deploy-hub' first"; \
		exit 1; \
	fi; \
	aws cloudformation create-stack-set \
		--stack-set-name $(AWS_STACK_NAME) \
		--template-body file://aws/cloudformation/spoke.yaml \
		--parameters \
			ParameterKey=HubAccountId,ParameterValue=$(HUB_ACCOUNT_ID) \
			ParameterKey=HubBucketName,ParameterValue=$(HUB_BUCKET) \
			ParameterKey=HubSecretArn,ParameterValue=$$SECRET_ARN \
		--capabilities CAPABILITY_NAMED_IAM \
		--permission-model SERVICE_MANAGED \
		--auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
		--region $(AWS_REGION) 2>/dev/null || \
		aws cloudformation update-stack-set \
			--stack-set-name $(AWS_STACK_NAME) \
			--template-body file://aws/cloudformation/spoke.yaml \
			--parameters \
				ParameterKey=HubAccountId,ParameterValue=$(HUB_ACCOUNT_ID) \
				ParameterKey=HubBucketName,ParameterValue=$(HUB_BUCKET) \
				ParameterKey=HubSecretArn,ParameterValue=$$SECRET_ARN \
			--capabilities CAPABILITY_NAMED_IAM \
			--region $(AWS_REGION)
	@echo "StackSet created/updated"

aws-deploy-stackset-instances:
	@if [ -z "$(OU_IDS)" ]; then \
		echo "Error: OU_IDS not set"; \
		echo "Usage: make aws-deploy-stackset-instances OU_IDS=ou-xxxx-xxxxxxxx"; \
		exit 1; \
	fi
	aws cloudformation create-stack-instances \
		--stack-set-name $(AWS_STACK_NAME) \
		--deployment-targets OrganizationalUnitIds=$(OU_IDS) \
		--regions $(AWS_REGION) \
		--operation-preferences MaxConcurrentPercentage=25,FailureTolerancePercentage=10 \
		--region $(AWS_REGION)
	@echo "StackSet instances deploying to: $(OU_IDS)"

aws-delete-hub:
	aws cloudformation delete-stack --stack-name $(AWS_STACK_NAME)-hub --region $(AWS_REGION)
	@echo "Waiting for hub deletion..."
	aws cloudformation wait stack-delete-complete --stack-name $(AWS_STACK_NAME)-hub --region $(AWS_REGION)
	@echo "Hub deleted"

aws-delete-spoke:
	aws cloudformation delete-stack --stack-name $(AWS_STACK_NAME)-spoke --region $(AWS_REGION)
	@echo "Spoke deleted"

aws-delete-stackset:
	@if [ -z "$(OU_IDS)" ]; then \
		echo "Error: OU_IDS required to delete instances"; \
		exit 1; \
	fi
	aws cloudformation delete-stack-instances \
		--stack-set-name $(AWS_STACK_NAME) \
		--deployment-targets OrganizationalUnitIds=$(OU_IDS) \
		--regions $(AWS_REGION) \
		--no-retain-stacks \
		--region $(AWS_REGION) || true
	@echo "Waiting for instances to delete (60s)..."
	@sleep 60
	aws cloudformation delete-stack-set --stack-set-name $(AWS_STACK_NAME) --region $(AWS_REGION)
	@echo "StackSet deleted"

aws-delete-secret:
	aws secretsmanager delete-secret \
		--secret-id "$(AWS_STACK_NAME)-credentials" \
		--force-delete-without-recovery \
		--region $(AWS_REGION) 2>/dev/null && \
		echo "Secret deleted" || echo "Secret not found"

aws-status-hub:
	@aws cloudformation describe-stacks --stack-name $(AWS_STACK_NAME)-hub --region $(AWS_REGION) \
		--query 'Stacks[0].Outputs' --output table 2>/dev/null || echo "Hub not deployed"

aws-status-spoke:
	@aws cloudformation describe-stacks --stack-name $(AWS_STACK_NAME)-spoke --region $(AWS_REGION) \
		--query 'Stacks[0].Outputs' --output table 2>/dev/null || echo "Spoke not deployed"

aws-scan-instance:
	@if [ -z "$(INSTANCE_ID)" ]; then \
		echo "Error: INSTANCE_ID not set"; \
		exit 1; \
	fi
	aws lambda invoke \
		--function-name qualys-ssm-trigger \
		--payload '{"instance_ids":["$(INSTANCE_ID)"]}' \
		--region $(AWS_REGION) \
		/dev/stdout

aws-scan-fleet:
	aws lambda invoke \
		--function-name qualys-ssm-trigger \
		--payload '{"scan_type":"fleet"}' \
		--region $(AWS_REGION) \
		/dev/stdout

# =============================================================================
# AZURE BICEP
# =============================================================================

azure-deploy-hub:
	@if [ -z "$(QUALYS_ACCESS_TOKEN)" ]; then \
		echo "Error: QUALYS_ACCESS_TOKEN not set"; \
		exit 1; \
	fi
	az group create --name $(AZURE_RESOURCE_GROUP) --location $(AZURE_LOCATION) 2>/dev/null || true
	az deployment group create \
		--resource-group $(AZURE_RESOURCE_GROUP) \
		--template-file azure/bicep/hub.bicep \
		--parameters qualysPod=$(QUALYS_POD) qualysAccessToken=$(QUALYS_ACCESS_TOKEN)
	@echo "Hub deployed"

azure-deploy-spoke:
	@if [ -z "$(HUB_SUBSCRIPTION_ID)" ]; then \
		echo "Error: HUB_SUBSCRIPTION_ID not set"; \
		exit 1; \
	fi
	@if [ -z "$(HUB_RESOURCE_GROUP)" ]; then \
		echo "Error: HUB_RESOURCE_GROUP not set"; \
		exit 1; \
	fi
	@if [ -z "$(HUB_STORAGE_ACCOUNT)" ]; then \
		echo "Error: HUB_STORAGE_ACCOUNT not set"; \
		exit 1; \
	fi
	@if [ -z "$(HUB_KEY_VAULT)" ]; then \
		echo "Error: HUB_KEY_VAULT not set"; \
		exit 1; \
	fi
	az group create --name $(AZURE_RESOURCE_GROUP) --location $(AZURE_LOCATION) 2>/dev/null || true
	az deployment group create \
		--resource-group $(AZURE_RESOURCE_GROUP) \
		--template-file azure/bicep/spoke.bicep \
		--parameters \
			hubSubscriptionId=$(HUB_SUBSCRIPTION_ID) \
			hubResourceGroup=$(HUB_RESOURCE_GROUP) \
			hubStorageAccountName=$(HUB_STORAGE_ACCOUNT) \
			hubKeyVaultName=$(HUB_KEY_VAULT)
	@echo "Spoke deployed"

azure-delete-hub:
	az group delete --name $(AZURE_RESOURCE_GROUP) --yes --no-wait
	@echo "Hub deletion initiated"

azure-delete-spoke:
	az group delete --name $(AZURE_RESOURCE_GROUP) --yes --no-wait
	@echo "Spoke deletion initiated"

# =============================================================================
# GCP TERRAFORM
# =============================================================================

gcp-deploy-hub:
	@if [ -z "$(QUALYS_ACCESS_TOKEN)" ]; then \
		echo "Error: QUALYS_ACCESS_TOKEN not set"; \
		exit 1; \
	fi
	@if [ -z "$(GCP_PROJECT)" ]; then \
		echo "Error: GCP_PROJECT not set"; \
		exit 1; \
	fi
	cd gcp/terraform/hub && \
		terraform init && \
		terraform apply -auto-approve \
			-var="project_id=$(GCP_PROJECT)" \
			-var="region=$(GCP_REGION)" \
			-var="qualys_pod=$(QUALYS_POD)" \
			-var="qualys_access_token=$(QUALYS_ACCESS_TOKEN)"
	@echo "Hub deployed"

gcp-deploy-spoke:
	@if [ -z "$(GCP_PROJECT)" ]; then \
		echo "Error: GCP_PROJECT not set"; \
		exit 1; \
	fi
	@if [ -z "$(HUB_PROJECT_ID)" ]; then \
		echo "Error: HUB_PROJECT_ID not set"; \
		exit 1; \
	fi
	@if [ -z "$(HUB_BUCKET_NAME)" ]; then \
		echo "Error: HUB_BUCKET_NAME not set"; \
		exit 1; \
	fi
	@if [ -z "$(HUB_SECRET_ID)" ]; then \
		echo "Error: HUB_SECRET_ID not set"; \
		exit 1; \
	fi
	cd gcp/terraform/spoke && \
		terraform init && \
		terraform apply -auto-approve \
			-var="project_id=$(GCP_PROJECT)" \
			-var="region=$(GCP_REGION)" \
			-var="hub_project_id=$(HUB_PROJECT_ID)" \
			-var="hub_bucket_name=$(HUB_BUCKET_NAME)" \
			-var="hub_secret_id=$(HUB_SECRET_ID)"
	@echo "Spoke deployed"

gcp-delete-hub:
	cd gcp/terraform/hub && terraform destroy -auto-approve
	@echo "Hub deleted"

gcp-delete-spoke:
	cd gcp/terraform/spoke && terraform destroy -auto-approve
	@echo "Spoke deleted"

# =============================================================================
# UNIFIED TERRAFORM
# =============================================================================

tf-init:
	cd $(TF_DIR) && terraform init

tf-plan:
	cd $(TF_DIR) && terraform plan

tf-apply:
	cd $(TF_DIR) && terraform apply

tf-destroy:
	cd $(TF_DIR) && terraform destroy

# =============================================================================
# CLEANUP
# =============================================================================

clean:
	rm -rf build/
	rm -rf gcp/terraform/hub/.terraform gcp/terraform/hub/.terraform.lock.hcl
	rm -rf gcp/terraform/spoke/.terraform gcp/terraform/spoke/.terraform.lock.hcl
	rm -rf terraform/modules/*/.terraform terraform/modules/*/.terraform.lock.hcl
	@echo "Build artifacts cleaned"

clean-all: aws-delete-secret clean
	@echo "Full cleanup complete"
