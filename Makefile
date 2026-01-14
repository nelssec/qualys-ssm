# Qualys SSM Scanner - Makefile
SHELL := /bin/bash

# Configuration
STACK_NAME ?= qualys-ssm-scanner
AWS_REGION ?= $(shell aws configure get region || echo "us-east-1")
QUALYS_POD ?= US2
SCAN_TYPES ?= os,sca,fileinsight

# Colors
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
NC := \033[0m

.PHONY: help deploy update delete status scan-instance scan-fleet upload-qscanner validate lint clean

help: ## Show this help
	@echo "Qualys SSM Scanner"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-20s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "Environment Variables:"
	@echo "  STACK_NAME         Stack name (default: qualys-ssm-scanner)"
	@echo "  AWS_REGION         AWS region (default: from AWS CLI config)"
	@echo "  QUALYS_POD         Qualys POD (default: US2)"
	@echo "  QUALYS_TOKEN       Qualys access token (required for deploy)"
	@echo "  INSTANCE_ID        EC2 instance ID (for scan-instance)"

validate: ## Validate CloudFormation template
	@echo "$(YELLOW)Validating CloudFormation template...$(NC)"
	@aws cloudformation validate-template \
		--template-body file://cloudformation/qualys-ssm-scanner.yaml \
		--region $(AWS_REGION) > /dev/null
	@echo "$(GREEN)Template is valid$(NC)"

deploy: validate ## Deploy the CloudFormation stack
	@if [ -z "$(QUALYS_TOKEN)" ]; then \
		echo "$(RED)Error: QUALYS_TOKEN environment variable is required$(NC)"; \
		echo "Usage: QUALYS_TOKEN=your-token make deploy"; \
		exit 1; \
	fi
	@echo "$(YELLOW)Deploying stack $(STACK_NAME) to $(AWS_REGION)...$(NC)"
	@aws cloudformation deploy \
		--stack-name $(STACK_NAME) \
		--template-file cloudformation/qualys-ssm-scanner.yaml \
		--parameter-overrides \
			QualysAccessToken=$(QUALYS_TOKEN) \
			QualysPod=$(QUALYS_POD) \
			ScanTypes=$(SCAN_TYPES) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--tags Application=QualysSSMScanner
	@echo "$(GREEN)Deployment complete$(NC)"
	@$(MAKE) status

update: validate ## Update an existing stack
	@if [ -z "$(QUALYS_TOKEN)" ]; then \
		echo "$(RED)Error: QUALYS_TOKEN environment variable is required$(NC)"; \
		exit 1; \
	fi
	@echo "$(YELLOW)Updating stack $(STACK_NAME)...$(NC)"
	@aws cloudformation update-stack \
		--stack-name $(STACK_NAME) \
		--template-body file://cloudformation/qualys-ssm-scanner.yaml \
		--parameters \
			ParameterKey=QualysAccessToken,ParameterValue=$(QUALYS_TOKEN) \
			ParameterKey=QualysPod,ParameterValue=$(QUALYS_POD) \
			ParameterKey=ScanTypes,ParameterValue=$(SCAN_TYPES) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) || true
	@echo "$(YELLOW)Waiting for update to complete...$(NC)"
	@aws cloudformation wait stack-update-complete \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION) || true
	@$(MAKE) status

delete: ## Delete the CloudFormation stack
	@echo "$(RED)Deleting stack $(STACK_NAME)...$(NC)"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ]
	@aws cloudformation delete-stack \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION)
	@echo "$(YELLOW)Waiting for deletion to complete...$(NC)"
	@aws cloudformation wait stack-delete-complete \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION)
	@echo "$(GREEN)Stack deleted$(NC)"

status: ## Show stack status and outputs
	@echo "$(YELLOW)Stack Status:$(NC)"
	@aws cloudformation describe-stacks \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION) \
		--query 'Stacks[0].{Status:StackStatus,Created:CreationTime,Updated:LastUpdatedTime}' \
		--output table 2>/dev/null || echo "Stack not found"
	@echo ""
	@echo "$(YELLOW)Stack Outputs:$(NC)"
	@aws cloudformation describe-stacks \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION) \
		--query 'Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}' \
		--output table 2>/dev/null || true

scan-instance: ## Scan a specific EC2 instance (requires INSTANCE_ID)
	@if [ -z "$(INSTANCE_ID)" ]; then \
		echo "$(RED)Error: INSTANCE_ID is required$(NC)"; \
		echo "Usage: INSTANCE_ID=i-xxxxx make scan-instance"; \
		exit 1; \
	fi
	@echo "$(YELLOW)Triggering scan for $(INSTANCE_ID)...$(NC)"
	@aws lambda invoke \
		--function-name QualysSSMScanner-Trigger \
		--payload '{"instance_ids":["$(INSTANCE_ID)"]}' \
		--region $(AWS_REGION) \
		/tmp/scan-response.json > /dev/null
	@cat /tmp/scan-response.json | jq .
	@rm -f /tmp/scan-response.json

scan-fleet: ## Scan all instances tagged with QualysScan=enabled
	@echo "$(YELLOW)Triggering fleet scan...$(NC)"
	@aws lambda invoke \
		--function-name QualysSSMScanner-Trigger \
		--payload '{"scan_type":"fleet"}' \
		--region $(AWS_REGION) \
		/tmp/scan-response.json > /dev/null
	@cat /tmp/scan-response.json | jq .
	@rm -f /tmp/scan-response.json

scan-all: ## Scan ALL running EC2 instances
	@echo "$(RED)Warning: This will scan ALL running EC2 instances$(NC)"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ]
	@echo "$(YELLOW)Triggering scan for all instances...$(NC)"
	@aws lambda invoke \
		--function-name QualysSSMScanner-Trigger \
		--payload '{"scan_type":"all"}' \
		--region $(AWS_REGION) \
		/tmp/scan-response.json > /dev/null
	@cat /tmp/scan-response.json | jq .
	@rm -f /tmp/scan-response.json

upload-qscanner: ## Upload QScanner binary to S3
	@BUCKET=$$(aws cloudformation describe-stacks \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION) \
		--query 'Stacks[0].Outputs[?OutputKey==`ResultsBucketName`].OutputValue' \
		--output text); \
	if [ -z "$$BUCKET" ]; then \
		echo "$(RED)Error: Could not find results bucket. Is the stack deployed?$(NC)"; \
		exit 1; \
	fi; \
	echo "$(YELLOW)Uploading QScanner binaries to s3://$$BUCKET/qscanner/$(NC)"; \
	if [ -f "qscanner-linux-amd64" ]; then \
		aws s3 cp qscanner-linux-amd64 s3://$$BUCKET/qscanner/qscanner-linux-amd64 --region $(AWS_REGION); \
	fi; \
	if [ -f "qscanner-linux-arm64" ]; then \
		aws s3 cp qscanner-linux-arm64 s3://$$BUCKET/qscanner/qscanner-linux-arm64 --region $(AWS_REGION); \
	fi; \
	echo "$(GREEN)Upload complete$(NC)"; \
	aws s3 ls s3://$$BUCKET/qscanner/ --region $(AWS_REGION)

list-scans: ## List recent scan results
	@BUCKET=$$(aws cloudformation describe-stacks \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION) \
		--query 'Stacks[0].Outputs[?OutputKey==`ResultsBucketName`].OutputValue' \
		--output text); \
	echo "$(YELLOW)Recent scans in s3://$$BUCKET/scans/$(NC)"; \
	aws s3 ls s3://$$BUCKET/scans/ --region $(AWS_REGION) | tail -20

get-scan-results: ## Get scan results for an instance (requires INSTANCE_ID)
	@if [ -z "$(INSTANCE_ID)" ]; then \
		echo "$(RED)Error: INSTANCE_ID is required$(NC)"; \
		exit 1; \
	fi
	@BUCKET=$$(aws cloudformation describe-stacks \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION) \
		--query 'Stacks[0].Outputs[?OutputKey==`ResultsBucketName`].OutputValue' \
		--output text); \
	echo "$(YELLOW)Scan results for $(INSTANCE_ID):$(NC)"; \
	aws s3 ls s3://$$BUCKET/scans/$(INSTANCE_ID)/ --region $(AWS_REGION) --recursive

check-ssm-status: ## Check SSM agent status on running instances
	@echo "$(YELLOW)Checking SSM agent status...$(NC)"
	@aws ssm describe-instance-information \
		--region $(AWS_REGION) \
		--query 'InstanceInformationList[*].{InstanceId:InstanceId,PingStatus:PingStatus,Platform:PlatformType,AgentVersion:AgentVersion}' \
		--output table

ssm-run-status: ## Check status of SSM Run Command executions
	@echo "$(YELLOW)Recent SSM Run Command executions:$(NC)"
	@aws ssm list-commands \
		--region $(AWS_REGION) \
		--max-results 10 \
		--query 'Commands[*].{CommandId:CommandId,Status:Status,DocumentName:DocumentName,Targets:TargetCount,RequestedTime:RequestedDateTime}' \
		--output table

lint: ## Lint Python code
	@echo "$(YELLOW)Linting Python code...$(NC)"
	@python -m py_compile lambda/src/handler.py
	@echo "$(GREEN)Lint passed$(NC)"

clean: ## Clean temporary files
	@echo "$(YELLOW)Cleaning temporary files...$(NC)"
	@rm -rf lambda/src/__pycache__
	@rm -f /tmp/scan-response.json
	@rm -rf .pytest_cache
	@echo "$(GREEN)Clean complete$(NC)"
