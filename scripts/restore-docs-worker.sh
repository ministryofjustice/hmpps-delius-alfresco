#!/bin/bash

restore_from_glacier() {
    local S3_BUCKET_NAME=$1
    local S3_OBJECT_KEY=$2
    local JOB_TIER=${3:-Expedited}

    aws s3api restore-object \
        --bucket "$S3_BUCKET_NAME" \
        --key "$S3_OBJECT_KEY" \
        --restore-request '{"Days":1,"GlacierJobParameters":{"Tier":"'"$job_tier"'"}}'
}

check_restore_status() {
    local S3_BUCKET_NAME=$1
    local S3_OBJECT_KEY=$2

    local restore_status=$(aws s3api head-object --bucket "$S3_BUCKET_NAME" --key "$S3_OBJECT_KEY" | jq -r '.Restore')
    if [[ "$restore_status" == *"ongoing-request=\"true\""* ]]; then
        return 0 #restore in progress
    else
        return 1 #restore complete
    fi
}

copy_s3_object() {
    local S3_BUCKET_NAME=$1
    local S3_OBJECT_KEY=$2

    # Copy object within S3 bucket to update storage class
    aws s3 cp "s3://$S3_BUCKET_NAME/$S3_OBJECT_KEY" "s3://$S3_BUCKET_NAME/$S3_OBJECT_KEY" --storage-class STANDARD
}

lambda_handler() {
    local S3_BUCKET_NAME=$BUCKET_NAME
    local S3_OBJECT_KEY=$OBJECT_KEY

    if [[ -z "$S3_BUCKET_NAME" || -z "$S3_OBJECT_KEY" ]]; then
        echo "Please provide bucket name and object key"
        exit 1
    fi

    local object_versions=$(aws s3api list-object-versions --bucket "$S3_BUCKET_NAME" --prefix "$S3_OBJECT_KEY")
    if [[ -z "$object_versions" ]]; then
        echo "Object not found in bucket"
        exit 1
    fi

    local delete_markers=$(jq -r '.DeleteMarkers' <<< "$object_versions")
    if [[ -n "$delete_markers" ]]; then
        local version_id=$(jq -r '.[0].VersionId' <<< "$delete_markers")
        aws s3api delete-object --bucket "$S3_BUCKET_NAME" --key "$S3_OBJECT_KEY" --version-id "$version_id"
        echo "Deleted marker version: $version_id"
    fi

    # Restore object from Glacier
    restore_from_glacier "$S3_BUCKET_NAME" "$S3_OBJECT_KEY"

    # Wait for restoration to complete
    local wait_interval=20
    while check_restore_status "$S3_BUCKET_NAME" "$S3_OBJECT_KEY"; do
        echo "Restore for object s3://${S3_BUCKET_NAME}/${S3_OBJECT_KEY} in progress. Please wait!"
        sleep "$wait_interval"
    done

    # Copy object within S3 bucket to update storage class
    copy_s3_object "$S3_BUCKET_NAME" "$S3_OBJECT_KEY"

    echo "Restore for object s3://${S3_BUCKET_NAME}/${S3_OBJECT_KEY} task complete."
}

lambda_handler
