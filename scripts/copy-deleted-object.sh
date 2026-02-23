#!/usr/bin/env bash
set -euo pipefail

# This script copies a deleted S3 object (with delete marker) to another bucket.
# It retrieves the most recent non-delete-marker version of the object and copies it.
# Copy this script onto the Utils pod and run it from there.

# ========= CONFIG =========
SRC_BUCKET="${SRC_BUCKET:-tf-eu-west-2-hmpps-delius-*-alfresco-storage-s3bucket}"
DEST_BUCKET="${DEST_BUCKET:-cloud-platform-*}"
REGION="${AWS_REGION:-eu-west-2}"

# Object key to copy (required)
OBJECT_KEY="${OBJECT_KEY:-}"

# Set DRY_RUN=1 to preview operations
DRY_RUN="${DRY_RUN:-1}"

# Logging
LOGFILE="${LOGFILE:-./copy-deleted-object.$(date +%Y%m%d-%H%M%S).log}"
AWS_PAGER=""  # disable aws pager

log() { printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE" >&2; }
req() { command -v "$1" >/dev/null || { log "ERROR: required command '$1' not found"; exit 1; }; }

req aws; req jq

# Validate required parameters
if [[ -z "$OBJECT_KEY" ]]; then
  log "ERROR: OBJECT_KEY environment variable is required"
  log "Usage: OBJECT_KEY=2018/5/1/12/24/b3b6ba1a-da97-4009-902a-6742e43381ef.bin $0"
  exit 1
fi

# Strip s3:// prefix if provided
OBJECT_KEY="${OBJECT_KEY#s3://}"

log "Source:      s3://$SRC_BUCKET/$OBJECT_KEY"
log "Destination: s3://$DEST_BUCKET/$OBJECT_KEY"
log "Region:      $REGION"
[[ "$DRY_RUN" == "1" ]] && log "DRY-RUN enabled (set DRY_RUN=0 to execute)"

# Get all versions of the object
log "Retrieving versions for key: $OBJECT_KEY"
versions_json=$(aws s3api list-object-versions \
  --bucket "$SRC_BUCKET" \
  --region "$REGION" \
  --prefix "$OBJECT_KEY" \
  --output json 2>/dev/null)

# Check if object exists
if [[ -z "$versions_json" ]] || [[ "$versions_json" == "null" ]]; then
  log "ERROR: No versions found for key: $OBJECT_KEY"
  exit 1
fi

# Check for delete markers
delete_markers=$(echo "$versions_json" | jq -r '.DeleteMarkers[]? | select(.Key == "'"$OBJECT_KEY"'") | .VersionId' | head -1)

if [[ -z "$delete_markers" ]]; then
  log "INFO: No delete marker found - object is not deleted"
  log "Checking if current version exists..."
  current_version=$(echo "$versions_json" | jq -r '.Versions[]? | select(.Key == "'"$OBJECT_KEY"'" and .IsLatest == true) | .VersionId' | head -1)
  
  if [[ -z "$current_version" ]]; then
    log "ERROR: Object not found: $OBJECT_KEY"
    exit 1
  fi
  
  log "Current version: $current_version"
  version_to_copy="$current_version"
else
  log "Delete marker found - retrieving most recent non-delete-marker version"
  
  # Get the most recent version that is not a delete marker
  version_to_copy=$(echo "$versions_json" | jq -r '.Versions[]? | select(.Key == "'"$OBJECT_KEY"'") | .VersionId' | head -1)
  
  if [[ -z "$version_to_copy" ]]; then
    log "ERROR: No non-delete-marker versions found for key: $OBJECT_KEY"
    exit 1
  fi
  
  log "Most recent version: $version_to_copy"
fi

# Get object metadata
metadata=$(aws s3api head-object \
  --bucket "$SRC_BUCKET" \
  --region "$REGION" \
  --key "$OBJECT_KEY" \
  --version-id "$version_to_copy" \
  --output json 2>/dev/null)

size=$(echo "$metadata" | jq -r '.ContentLength')
last_modified=$(echo "$metadata" | jq -r '.LastModified')

log "Object size: $size bytes"
log "Last modified: $last_modified"

# Copy the object
if [[ "$DRY_RUN" == "1" ]]; then
  log "[DRY-RUN] Would copy: s3://$SRC_BUCKET/$OBJECT_KEY?versionId=$version_to_copy -> s3://$DEST_BUCKET/$OBJECT_KEY"
else
  log "Copying object..."
  aws s3api copy-object \
    --copy-source "$(printf '%s/%s?versionId=%s' "$SRC_BUCKET" "$OBJECT_KEY" "$version_to_copy")" \
    --bucket "$DEST_BUCKET" \
    --key "$OBJECT_KEY" \
    --region "$REGION" \
    --output json | tee -a "$LOGFILE"
  
  log "Copy completed successfully"
fi

log "Done."
