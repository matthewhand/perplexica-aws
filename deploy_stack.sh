#!/bin/bash

# Usage: ./deploy_stack.sh <STACK_TYPE> <AWS_REGION> <RESOURCE_PREFIX> [Key=Value]...

#set -x  # Enable debug output

# Capture input parameters
STACK_TYPE=$1
REGION=$2
RESOURCE_PREFIX=$3
shift 3  # Shift the first three positional arguments out, leaving only key-value pairs

# Derive template filename from the stack type
TEMPLATE_FILE="cfn/${STACK_TYPE}-template.yaml"
STACK_NAME="${RESOURCE_PREFIX}-${STACK_TYPE}-stack"

# Check if the template file exists
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "Error: Template file does not exist - $TEMPLATE_FILE"
    exit 1
fi

# Prepare parameter overrides
PARAM_OVERRIDES="ResourcePrefix=${RESOURCE_PREFIX}"
for ARG in "$@"; do
    if [[ "$ARG" == *=* ]]; then
        PARAM_OVERRIDES="$PARAM_OVERRIDES $ARG"
    fi
done

# Trim leading/trailing spaces from PARAM_OVERRIDES
PARAM_OVERRIDES=$(echo "$PARAM_OVERRIDES" | xargs)

# Debugging: Print parameter overrides
if [ -n "$PARAM_OVERRIDES" ]; then
    echo "Using parameter overrides: $PARAM_OVERRIDES"
else
    echo "No parameter overrides provided."
fi

# Function to describe CloudFormation stack events
describe_stack_events() {
    local stack_name=$1
    local region=$2
    echo "Fetching stack events for ${stack_name}..."
    aws cloudformation describe-stack-events \
        --stack-name "${stack_name}" \
        --region "${region}" \
        --query "StackEvents[*].{ResourceStatus:ResourceStatus,ResourceType:ResourceType,LogicalResourceId:LogicalResourceId,Timestamp:Timestamp,ResourceStatusReason:ResourceStatusReason}" \
        --output table
}

# Function to check rollback state
is_rollback() {
    local stack_status=$1
    [[ "$stack_status" == "ROLLBACK_COMPLETE" ]] || [[ "$stack_status" == "UPDATE_ROLLBACK_COMPLETE" ]] || [[ "$stack_status" == "ROLLBACK_IN_PROGRESS" ]] || [[ "$stack_status" == "UPDATE_ROLLBACK_IN_PROGRESS" ]]
}

# Function to check stack status and handle rollback states
check_and_handle_stack_status() {
    local stack_name=$1
    local region=$2
    local status

    status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$region" --query "Stacks[0].StackStatus" --output text 2>/dev/null)

    if is_rollback "$status"; then
        echo "Stack $stack_name is in $status state. Deleting it before redeploying..."
        aws cloudformation delete-stack --stack-name "$stack_name" --region "$region"
        echo "Waiting for stack $stack_name to be deleted..."
        aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "$region"
    fi
}

# Function to retry commands with exponential backoff
retry_with_backoff() {
    local max_attempts=$1
    local initial_sleep=$2
    shift 2
    local attempt=1
    local exit_code=0
    local sleep_time=$initial_sleep

    while [ $attempt -le $max_attempts ]; do
        "$@"
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            return 0
        elif [ $exit_code -eq 255 ]; then
            echo "Stack $STACK_NAME is in a terminal rollback state or cannot be updated. Exiting without retry."
            return $exit_code
        fi
        echo "Attempt $attempt failed with exit code $exit_code. Retrying in $sleep_time seconds..."
        sleep $sleep_time
        attempt=$(( attempt + 1 ))
        sleep_time=$(( sleep_time * 2 ))
    done

    echo "All $max_attempts attempts failed."
    return $exit_code
}

# Check current stack status and handle rollback states
check_and_handle_stack_status "$STACK_NAME" "$REGION"

# Construct deployment command with conditional parameter overrides
DEPLOY_CMD="aws cloudformation deploy \
    --template-file $TEMPLATE_FILE \
    --stack-name $STACK_NAME \
    --region $REGION \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --output json"

if [ -n "$PARAM_OVERRIDES" ];then
    DEPLOY_CMD+=" --parameter-overrides $PARAM_OVERRIDES"
fi

# Debugging: Print the final deploy command
echo "Final deployment command: $DEPLOY_CMD"

# Execute the deployment command and handle exit code 255 (no changes required)
set +e
retry_with_backoff 3 10 eval $DEPLOY_CMD
DEPLOY_EXIT_CODE=$?
set -e

if [ $DEPLOY_EXIT_CODE -eq 255 ]; then
    echo "No changes to deploy. Stack $STACK_NAME is up to date."
elif [ $DEPLOY_EXIT_CODE -ne 0 ]; then
    echo "Deployment command failed with exit code $DEPLOY_EXIT_CODE."
    describe_stack_events "$STACK_NAME" "$REGION"
    exit $DEPLOY_EXIT_CODE
fi

# Check if the stack is in a rollback state after deployment
STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --query "Stacks[0].StackStatus" --output text 2>/dev/null)

if is_rollback "$STACK_STATUS"; then
    echo "Stack $STACK_NAME is in $STACK_STATUS state. Dumping stack events for troubleshooting..."
    describe_stack_events "$STACK_NAME" "$REGION"
    exit 1
fi

# Debugging: Output the resources of the stack as JSON
echo "Describing resources for stack: $STACK_NAME"
aws cloudformation describe-stack-resources --stack-name $STACK_NAME --region $REGION
