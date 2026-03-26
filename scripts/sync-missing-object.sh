#!/usr/bin/env bash
set -euo pipefail

# This script checks if an object exists in the destination S3 bucket.
# If it doesn't exist, it syncs it from the legacy environment bucket.
# Copy this script onto the Utils pod and run it from there.
# 
# Usage: ./sync-missing-object.sh <s3-path>
# Example: ./sync-missing-object.sh "s3v2://2025/12/8/11/18/bbf804a1-815f-465f-8fc4-e2300d47708b.bin"

# ========= CONFIG =========
SRC_BUCKET="${SRC_BUCKET:-tf-eu-west-2-hmpps-delius-*-alfresco-storage-s3bucket}"
DEST_BUCKET="${DEST_BUCKET:-cloud-platform-*}"
REGION="${AWS_REGION:-eu-west-2}"

# Set DRY_RUN=1 to preview operations
DRY_RUN="${DRY_RUN:-0}"

# Logging
AWS_PAGER=""  # disable aws pager

log() { printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
req() { command -v "$1" >/dev/null || { log "ERROR: required command '$1' not found"; exit 1; }; }

req aws

# Check arguments
if [[ $# -ne 1 ]]; then
  log "ERROR: Missing required argument"
  log "Usage: $0 <s3-path>"
  log "Example: $0 's3v2://2025/12/8/11/18/bbf804a1-815f-465f-8fc4-e2300d47708b.bin'"
  exit 1
fi

INPUT_PATH="$1"

# Parse the input path - strip s3v2:// prefix if present
OBJECT_KEY="${INPUT_PATH#s3v2://}"
OBJECT_KEY="${OBJECT_KEY#/}"  # strip leading slash if present

if [[ -z "$OBJECT_KEY" ]]; then
  log "ERROR: Invalid S3 path: $INPUT_PATH"
  exit 1
fi

log "Checking object: $OBJECT_KEY"
log "Destination bucket: s3://$DEST_BUCKET"
log "Source bucket: s3://$SRC_BUCKET"

# Check if object exists in destination bucket
log "Checking if object exists in destination bucket..."
if aws s3api head-object \
  --bucket "$DEST_BUCKET" \
  --key "$OBJECT_KEY" \
  --region "$REGION" >/dev/null 2>&1; then
  log "SUCCESS: Object already exists in destination bucket: s3://$DEST_BUCKET/$OBJECT_KEY"
  exit 0
else
  log "Object not found in destination bucket"
fi

# Check if object exists in source bucket
log "Checking if object exists in source bucket..."
if ! aws s3api head-object \
  --bucket "$SRC_BUCKET" \
  --key "$OBJECT_KEY" \
  --region "$REGION" >/dev/null 2>&1; then
  log "ERROR: Object not found in source bucket either: s3://$SRC_BUCKET/$OBJECT_KEY"
  exit 1
fi

log "Object found in source bucket"

# Copy the object from source to destination
if [[ "$DRY_RUN" == "1" ]]; then
  log "[DRY-RUN] Would copy: s3://$SRC_BUCKET/$OBJECT_KEY -> s3://$DEST_BUCKET/$OBJECT_KEY"
else
  log "Copying object from source to destination..."
  if aws s3 cp \
    "s3://$SRC_BUCKET/$OBJECT_KEY" \
    "s3://$DEST_BUCKET/$OBJECT_KEY" \
    --region "$REGION" \
    --only-show-errors; then
    log "SUCCESS: Object copied successfully"
  else
    log "ERROR: Failed to copy object"
    exit 1
  fi
fi

log "Done."
