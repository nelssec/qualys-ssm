STACK_NAME ?= qualys-ssm-scanner
AWS_REGION ?= $(shell aws configure get region || echo "us-east-1")
QUALYS_POD ?= US2

.PHONY: deploy update delete status scan-instance scan-fleet validate

validate:
	@aws cloudformation validate-template --template-body file://cloudformation/qualys-ssm-scanner.yaml --region $(AWS_REGION)

deploy: validate
	@aws cloudformation deploy \
		--stack-name $(STACK_NAME) \
		--template-file cloudformation/qualys-ssm-scanner.yaml \
		--parameter-overrides \
			QualysAccessToken=$(QUALYS_TOKEN) \
			QualysPod=$(QUALYS_POD) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION)

delete:
	@aws cloudformation delete-stack --stack-name $(STACK_NAME) --region $(AWS_REGION)
	@aws cloudformation wait stack-delete-complete --stack-name $(STACK_NAME) --region $(AWS_REGION)

status:
	@aws cloudformation describe-stacks --stack-name $(STACK_NAME) --region $(AWS_REGION) --query 'Stacks[0].Outputs' --output table

scan-instance:
	@aws lambda invoke --function-name QualysSSMScanner-Trigger --payload '{"instance_ids":["$(INSTANCE_ID)"]}' --region $(AWS_REGION) /dev/stdout

scan-fleet:
	@aws lambda invoke --function-name QualysSSMScanner-Trigger --payload '{"scan_type":"fleet"}' --region $(AWS_REGION) /dev/stdout
