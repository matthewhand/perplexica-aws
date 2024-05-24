#!/bin/bash

# Usage: ./create_bucket.sh <AWS_REGION> <S3_BUCKET_NAME>

REGION=$1
BUCKET_NAME=$2

# Check if the bucket already exists
if aws s3api head-bucket --bucket $BUCKET_NAME 2>/dev/null; then
    echo "Bucket $BUCKET_NAME already exists."
else
    # Try creating the bucket
    if aws s3api create-bucket --bucket $BUCKET_NAME --region $REGION --create-bucket-configuration LocationConstraint=$REGION; then
        echo "Bucket $BUCKET_NAME created successfully."
    else
        echo "Failed to create bucket $BUCKET_NAME."
        exit 1
    fi
fi
