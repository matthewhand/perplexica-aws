#!/bin/bash

# Usage: ./prepare_model.sh <HF_MODEL> <AWS_REGION> <S3_BUCKET_PATH>

MODEL=$1
REGION=$2
S3_BUCKET_PATH=$3

# Path to the model tarball
MODEL_TARBALL="models/$MODEL/$MODEL.tar.gz"

# Ensure the model file exists
if [ ! -f $MODEL_TARBALL ]; then
    echo "Model tarball does not exist: $MODEL_TARBALL"
    exit 1
fi

# Upload the model to S3
echo "Uploading the model to S3..."
if aws s3 cp $MODEL_TARBALL s3://$S3_BUCKET_PATH --region $REGION; then
    echo "Model uploaded successfully to s3://$S3_BUCKET_PATH"
else
    echo "Failed to upload the model to s3://$S3_BUCKET_PATH"
    exit 1
fi

