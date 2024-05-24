SHELL := /bin/bash -e
.PHONY: all clean deploy fetch-ami-id setup-env check-create-bucket prepare-model \
	deploy-security-group deploy-iam-roles deploy-opensearch deploy-log-groups deploy-sagemaker deploy-ec2 \
	get-ec2-console-log apply-cw-log-policy delete-log-groups

include .env
export

AWS_REGION := us-west-2
RESOURCE_PREFIX := perplexica
MODEL_PATH := distilbert-base-uncased
HF_MODEL := distilbert-base-uncased
BUCKET_NAME_FILE := .s3_bucket_name

DEBUG_SHELL := bash
ifeq ($(DEBUG), true)
	DEBUG_SHELL := bash -x
endif

# Define log group names based on the resource prefix
SEARCH_LOG_GROUP := /aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/search-slow-logs
INDEX_LOG_GROUP := /aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/index-slow-logs

deploy: fetch-ami-id setup-env deploy-iam-roles deploy-security-group check-log-groups apply-cw-log-policy deploy-opensearch deploy-sagemaker deploy-ec2 get-ec2-console-log get-stack-status

apply-cw-log-policy:
	@echo "Applying CloudWatch Logs resource policy..."
	@{ \
		echo "{" > policy.json; \
		echo "    \"Version\": \"2012-10-17\"," >> policy.json; \
		echo "    \"Statement\": [" >> policy.json; \
		echo "        {" >> policy.json; \
		echo "            \"Effect\": \"Allow\"," >> policy.json; \
		echo "            \"Principal\": {\"Service\": \"opensearchservice.amazonaws.com\"}," >> policy.json; \
		echo "            \"Action\": [\"logs:CreateLogStream\", \"logs:PutLogEvents\"]," >> policy.json; \
		SEARCH_LOG_ARN=$$(aws logs describe-log-groups --region $(AWS_REGION) --log-group-name-prefix "/aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/search-slow-logs" --query "logGroups[0].arn" --output text); \
		INDEX_LOG_ARN=$$(aws logs describe-log-groups --region $(AWS_REGION) --log-group-name-prefix "/aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/index-slow-logs" --query "logGroups[0].arn" --output text); \
		echo "            \"Resource\": [\"$$SEARCH_LOG_ARN\", \"$$INDEX_LOG_ARN\"]" >> policy.json; \
		echo "        }" >> policy.json; \
		echo "    ]" >> policy.json; \
		echo "}" >> policy.json; \
		aws logs put-resource-policy --policy-name AllowOpenSearchLogs --policy-document file://policy.json; \
	}

check-log-groups:
	@echo "Checking for existing log groups..."
	@SEARCH_EXISTS=$$(aws logs describe-log-groups --region $(AWS_REGION) --log-group-name-prefix "/aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/search-slow-logs" --query "logGroups[?logGroupName=='/aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/search-slow-logs'].logGroupName" --output text); \
	INDEX_EXISTS=$$(aws logs describe-log-groups --region $(AWS_REGION) --log-group-name-prefix "/aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/index-slow-logs" --query "logGroups[?logGroupName=='/aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/index-slow-logs'].logGroupName" --output text); \
	if [ -z "$$SEARCH_EXISTS" ] && [ -z "$$INDEX_EXISTS" ]; then \
	echo "Log groups do not exist. Deploying log groups..."; \
	$(MAKE) deploy-log-groups; \
	else \
	echo "Log groups already exist. Skipping deployment of log groups."; \
	fi


deploy-log-groups:
	@echo "Checking for existing log groups..."
	@SEARCH_EXISTS=$$(aws logs describe-log-groups --region $(AWS_REGION) --log-group-name-prefix "/aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/search-slow-logs" --query "logGroups[?logGroupName=='/aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/search-slow-logs'].logGroupName" --output text); \
	INDEX_EXISTS=$$(aws logs describe-log-groups --region $(AWS_REGION) --log-group-name-prefix "/aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/index-slow-logs" --query "logGroups[?logGroupName=='/aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/index-slow-logs'].logGroupName" --output text); \
	if [ -z "$$SEARCH_EXISTS" ] && [ -z "$$INDEX_EXISTS" ]; then \
	echo "Log groups do not exist. Deploying log groups..."; \
	$(DEBUG_SHELL) ./deploy_stack.sh log-groups $(AWS_REGION) $(RESOURCE_PREFIX); \
	else \
	echo "Log groups already exist. Skipping deployment of log groups."; \
	fi


fetch-ami-id:
	$(eval AMI_ID := $(shell aws ssm get-parameter --name "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2" --region $(AWS_REGION) --query "Parameter.Value" --output text))
	@echo "Fetched AMI_ID: $(AMI_ID)"

deploy: fetch-ami-id setup-env deploy-iam-roles deploy-security-group deploy-log-groups deploy-opensearch deploy-sagemaker deploy-ec2 get-ec2-console-log

setup-env:
	@echo "Setting up environment files from .env..."
	@echo $(DEFAULT_VPC_ID) > .vpc_id
	@echo $(SUBNET_ID) > .subnet_id
	@echo "DEFAULT_VPC_ID is '$(DEFAULT_VPC_ID)'"
	@echo "SUBNET_ID is '$(SUBNET_ID)'"
	@echo "AWS_REGION is '$(AWS_REGION)'"

check-create-bucket:
	@if [ -f $(BUCKET_NAME_FILE) ]; then \
	echo "Using existing bucket from $(BUCKET_NAME_FILE)."; \
	export S3_BUCKET_NAME=$(RESOURCE_PREFIX)-bucket; \
	else \
	echo "Creating new bucket."; \
	S3_BUCKET_NAME=$(RESOURCE_PREFIX)-bucket; \
	echo $$S3_BUCKET_NAME > $(BUCKET_NAME_FILE); \
	./create_bucket.sh $(AWS_REGION) $$S3_BUCKET_NAME; \
	fi

prepare-model:
	@if [ -f $(BUCKET_NAME_FILE) ]; then \
	S3_BUCKET_NAME=`cat $(BUCKET_NAME_FILE)`; \
	./prepare_model.sh $(HF_MODEL) $(AWS_REGION) $$S3_BUCKET_NAME/$(MODEL_PATH); \
	else \
	echo "Bucket name file not found, aborting."; \
	exit 1; \
	fi

deploy-security-group:
	@echo "Deploying Security Group..."
	@echo "DEFAULT_VPC_ID is '$(DEFAULT_VPC_ID)'"
	@if [ -z "$(DEFAULT_VPC_ID)" ]; then \
	echo "Error: DEFAULT_VPC_ID is empty!"; \
	exit 1; \
	fi
	@$(DEBUG_SHELL) ./deploy_stack.sh security-group $(AWS_REGION) $(RESOURCE_PREFIX) VPCId=$(DEFAULT_VPC_ID)
	@aws cloudformation describe-stack-resources --stack-name "$(RESOURCE_PREFIX)-security-group-stack" --region $(AWS_REGION) --query "StackResources[?ResourceType=='AWS::EC2::SecurityGroup'].PhysicalResourceId" --output text > .security_group_id

deploy-iam-roles:
	@echo "Deploying general IAM roles..."
	@$(DEBUG_SHELL) ./deploy_stack.sh iam-roles $(AWS_REGION) $(RESOURCE_PREFIX) --template-file /home/chatgpt/perplexica-aws/cfn/iam-roles-template.yaml
	@echo "Deploying SageMaker and OpenSearch specific IAM roles..."
	@$(DEBUG_SHELL) ./deploy_stack.sh iam-roles $(AWS_REGION) $(RESOURCE_PREFIX) --template-file /home/chatgpt/perplexica-aws/cfn/iam-roles-sagemaker-opensearch.yaml
	@echo "IAM roles deployed successfully."

deploy-sagemaker:
	@echo "Deploying SageMaker..."
	@OPEN_SEARCH_SERVICE_ROLE_ARN=$$(aws cloudformation describe-stacks --stack-name "$(RESOURCE_PREFIX)-iam-roles-stack" --region $(AWS_REGION) --query "Stacks[0].Outputs[?OutputKey=='OpenSearchServiceRoleArn'].OutputValue" --output text) ; \
	SECURITY_GROUP_ID=$$(aws cloudformation describe-stack-resources --stack-name "$(RESOURCE_PREFIX)-security-group-stack" --region $(AWS_REGION) --query "StackResources[?ResourceType=='AWS::EC2::SecurityGroup'].PhysicalResourceId" --output text) ; \
	echo "IAM Role ARN for SageMaker is $$OPEN_SEARCH_SERVICE_ROLE_ARN" ; \
	echo "SECURITY_GROUP_ID is $$SECURITY_GROUP_ID" ; \
	if [ -z "$$OPEN_SEARCH_SERVICE_ROLE_ARN" ] || [ -z "$$SECURITY_GROUP_ID" ] || [ -z "$(SUBNET_ID)" ]; then \
	echo "Error: One or more parameters are empty (IAMRole, SecurityGroupId, SubnetId)."; \
	exit 1; \
	else \
	$(DEBUG_SHELL) ./deploy_stack.sh sagemaker $(AWS_REGION) $(RESOURCE_PREFIX) IAMRole="$$OPEN_SEARCH_SERVICE_ROLE_ARN" SecurityGroupId="$$SECURITY_GROUP_ID" SubnetId=$(SUBNET_ID); \
	echo "SageMaker deployed successfully."; \
	fi

deploy-opensearch:
	@echo "Deploying OpenSearch..."
	@SEARCH_ARN=$$(aws logs describe-log-groups --region $(AWS_REGION) --log-group-name-prefix "/aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/search-slow-logs" --query "logGroups[?logGroupName=='/aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/search-slow-logs'].arn" --output text); \
	INDEX_ARN=$$(aws logs describe-log-groups --region $(AWS_REGION) --log-group-name-prefix "/aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/index-slow-logs" --query "logGroups[?logGroupName=='/aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/index-slow-logs'].arn" --output text); \
	./deploy_stack.sh opensearch $(AWS_REGION) $(RESOURCE_PREFIX) VPCId=$(DEFAULT_VPC_ID) SubnetId=$(SUBNET_ID) SearchSlowLogsLogGroupArn="$$SEARCH_ARN" IndexSlowLogsLogGroupArn="$$INDEX_ARN"

deploy-ec2: fetch-ami-id
	@echo "Deploying EC2 Stack..."
	@echo "IAM_INSTANCE_PROFILE is `cat .iam_instance_profile_arn`"
	@echo "SECURITY_GROUP_ID is `cat .security_group_id`"
	@if [ -z "`cat .iam_instance_profile_arn`" ] || [ -z "`cat .security_group_id`" ] || [ -z "$(SUBNET_ID)" ] || [ -z "$(AMI_ID)" ]; then \
	echo "Error: One or more parameters are empty (IAMInstanceProfile, SecurityGroupId, SubnetId, AMIID)."; \
	exit 1; \
	fi
	@$(DEBUG_SHELL) ./deploy_stack.sh ec2 $(AWS_REGION) $(RESOURCE_PREFIX) IAMInstanceProfile=`cat .iam_instance_profile_arn` SecurityGroupId=`cat .security_group_id` SubnetId=$(SUBNET_ID) AMIID=$(AMI_ID)
	@echo "Capturing EC2 Instance Information..."
	@aws cloudformation describe-stacks --stack-name "$(RESOURCE_PREFIX)-ec2-stack" --region $(AWS_REGION) --query "Stacks[0].Outputs[?OutputKey=='InstancePublicIP'].OutputValue" --output text > ec2_instance_ip.txt
	@aws cloudformation describe-stacks --stack-name "$(RESOURCE_PREFIX)-ec2-stack" --region $(AWS_REGION) --query "Stacks[0].Outputs[?OutputKey=='InstanceFQDN'].OutputValue" --output text > ec2_instance_fqdn.txt
	@echo "EC2 Instance Public IP: `cat ec2_instance_ip.txt`"
	@echo "EC2 Instance FQDN: `cat ec2_instance_fqdn.txt`"

get-ec2-console-log:
	@$(DEBUG_SHELL) ./get_ec2_console_log_cfn.sh $(RESOURCE_PREFIX)-ec2-stack $(AWS_REGION)

get-stack-status:
	@aws cloudformation describe-stacks --region $(AWS_REGION) --output table --query "Stacks[*].[StackName,StackStatus]"

clean:
	@echo "Cleaning up..."
	@rm -f $(BUCKET_NAME_FILE) .iam_instance_profile_arn .security_group_id opensearch_domain_endpoint.txt sagemaker_instance_url.txt ec2_instance_ip.txt ec2_instance_fqdn.txt ec2_instance_id.txt
	@if [ -f ./clean_up.sh ]; then \
	$(DEBUG_SHELL) ./clean_up.sh $(AWS_REGION); \
	else \
	echo "clean_up.sh script not found. Skipping cleanup."; \
	fi

delete-log-groups:
	@echo "Deleting log groups..."
	@aws logs delete-log-group --log-group-name "/aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/search-slow-logs" --region $(AWS_REGION)
	@aws logs delete-log-group --log-group-name "/aws/aes/domains/$(RESOURCE_PREFIX)-os-domain/index-slow-logs" --region $(AWS_REGION)
	@echo "Log groups deleted."

