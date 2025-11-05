#!/usr/bin/env bash
set -euo pipefail

# Mirrors "deleted" objects from a source versioned bucket into a destination
# bucket by:
#   1) finding each delete marker in SOURCE
#   2) locating the immediately prior data version for that key
#   3) copying that prior version into DEST (preserving key path)
#   4) issuing a delete in DEST to create a delete marker there
#
# Notes / Limitations:
# - Delete marker timestamps and version IDs CANNOT be preserved; issuing a delete
#   in DEST will create a new delete marker "now".
# - Re-running the script is safe w.r.t DEST state but will add new versions;
#   use the STATE file to avoid reprocessing the same delete markers.
#
# Requirements: aws, jq
# Inspired by your existing version-paging/copy logic and constraints. 

# -------- Config --------
SRC_BUCKET="${SRC_BUCKET:-tf-eu-west-2-hmpps-delius-prod-alfresco-storage-s3bucket}"
DEST_BUCKET="${DEST_BUCKET:-cloud-platform-2d77db05a86a1eaa3e2406c09767fec9}"
REGION="${AWS_REGION:-eu-west-2}"
PREFIX="${PREFIX:-}"               # e.g. "2019/12/" or empty for whole bucket
DRY_RUN="${DRY_RUN:-1}"            # 1 = preview only, 0 = perform actions
STATE_FILE="${STATE_FILE:-./mirror-deletes.state}"  # remembers processed delete markers
LOGFILE="${LOGFILE:-./mirror-deletes.$(date +%Y%m%d-%H%M%S).log}"
AWS_PAGER=""

# -------- Helpers --------
log() { printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE" >&2; }
die() { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null || die "required command '$1' not found"; }
need aws; need jq

# URL-encode keys for --copy-source "bucket/key?versionId=..."
urlenc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1], safe="/"))' "$1"; }

mark_done() { echo "$1|$2" >> "$STATE_FILE"; }
is_done()   { grep -Fq "$1|$2" "$STATE_FILE" 2>/dev/null; }

log "Source: s3://$SRC_BUCKET/$PREFIX  →  Dest: s3://$DEST_BUCKET/$PREFIX"
log "Region: $REGION | DRY_RUN=$DRY_RUN | STATE_FILE=$STATE_FILE"

# -------- Pager over list-object-versions --------
token=""
total_markers=0
processed=0

while :; do
  if [[ -n "$token" ]]; then
    page=$(aws s3api list-object-versions \
      --bucket "$SRC_BUCKET" --region "$REGION" \
      --prefix "$PREFIX" --starting-token "$token")
  else
    page=$(aws s3api list-object-versions \
      --bucket "$SRC_BUCKET" --region "$REGION" \
      --prefix "$PREFIX")
  fi

  token=$(jq -r '."NextToken" // empty' <<<"$page")

  # Build a per-key timeline (most recent first) using both DeleteMarkers and Versions
  # We will walk each key's items; whenever we encounter a delete marker,
  # we look at the very next item in the timeline that is a data Version.
  jq -c '
    [
      (.DeleteMarkers[]? | {Key, IsLatest, LastModified, Type:"DeleteMarker", VersionId}) +
      {} ,
      (.Versions[]?       | {Key, IsLatest, LastModified, Type:"Version",      VersionId})
    ]
    | flatten
    | sort_by(.Key, (.LastModified) )        # S3 returns newest first per key, but we sort asc then iterate reverse
    | group_by(.Key)
    | map({key: .[0].Key, items: ( . | sort_by(.LastModified) | reverse )})
  ' <<<"$page" | while read -r group; do
    key=$(jq -r '.key' <<<"$group")
    items_json=$(jq -c '.items' <<<"$group")

    # Iterate items newest → oldest; for each delete marker, peek the next data version
    len=$(jq 'length' <<<"$items_json")
    for ((i=0; i<len; i++)); do
      item=$(jq -c ".[$i]" <<<"$items_json")
      type=$(jq -r '.Type' <<<"$item")
      [[ "$type" != "DeleteMarker" ]] && continue

      dm_vid=$(jq -r '.VersionId' <<<"$item")
      dm_time=$(jq -r '.LastModified' <<<"$item")
      ((total_markers++))

      if is_done "$key" "$dm_vid"; then
        log "Skip (already done): $key [delete marker $dm_vid @ $dm_time]"
        continue
      fi

      # find the immediately prior data version: the next element in this list with Type=="Version"
      prior=""
      for ((j=i+1; j<len; j++)); do
        cand=$(jq -c ".[$j]" <<<"$items_json")
        if [[ "$(jq -r '.Type' <<<"$cand")" == "Version" ]]; then
          prior="$cand"
          break
        fi
      done

      if [[ -z "$prior" ]]; then
        log "No prior data version for $key (delete marker $dm_vid). Will just create a delete marker in DEST."
        if [[ "$DRY_RUN" == "1" ]]; then
          log "[DRY-RUN] aws s3api delete-object --bucket \"$DEST_BUCKET\" --key \"$key\""
        else
          aws s3api delete-object --bucket "$DEST_BUCKET" --key "$key" --region "$REGION" >/dev/null
        fi
        mark_done "$key" "$dm_vid"
        ((processed++))
        continue
      fi

      prior_vid=$(jq -r '.VersionId' <<<"$prior")
      # Copy that exact source version
      copy_src="$(urlenc "$key")?versionId=$prior_vid"

      if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY-RUN] Copy prior version → DEST: aws s3api copy-object --copy-source \"$SRC_BUCKET/$copy_src\" --bucket \"$DEST_BUCKET\" --key \"$key\""
        log "[DRY-RUN] Create delete marker in DEST: aws s3api delete-object --bucket \"$DEST_BUCKET\" --key \"$key\""
      else
        aws s3api copy-object \
          --region "$REGION" \
          --copy-source "$SRC_BUCKET/$copy_src" \
          --bucket "$DEST_BUCKET" \
          --key "$key" \
          --metadata-directive COPY \
          >/dev/null

        # Create a delete marker in DEST (cannot backdate; this will be "now")
        aws s3api delete-object \
          --region "$REGION" \
          --bucket "$DEST_BUCKET" \
          --key "$key" \
          >/dev/null
      fi

      mark_done "$key" "$dm_vid"
      ((processed++))
    done
  done

  [[ -z "$token" ]] && break
done

log "Complete. Delete markers seen: $total_markers | processed this run: $processed | DRY_RUN=$DRY_RUN"