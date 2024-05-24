#!/bin/bash

# Usage: ./clean_up.sh <AWS_REGION>

REGION=$1

# Delete the CloudFormation stacks
aws cloudformation delete-stack --stack-name perplexica-iam-roles-stack --region $REGION
aws cloudformation delete-stack --stack-name perplexica-security-group-stack --region $REGION
aws cloudformation delete-stack --stack-name perplexica-opensearch-stack --region $REGION
aws cloudformation delete-stack --stack-name perplexica-ec2-stack --region $REGION

# Wait for stacks to be deleted
aws cloudformation wait stack-delete-complete --stack-name perplexica-iam-roles-stack --region $REGION
aws cloudformation wait stack-delete-complete --stack-name perplexica-security-group-stack --region $REGION
aws cloudformation wait stack-delete-complete --stack-name perplexica-opensearch-stack --region $REGION
aws cloudformation wait stack-delete-complete --stack-name perplexica-ec2-stack --region $REGION

echo "CloudFormation stacks deleted."
