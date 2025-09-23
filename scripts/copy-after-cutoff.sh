#!/usr/bin/env bash
set -euo pipefail

# This script is used for the CP migration to copy objects from one S3 bucket 
# to another from a particular point in time forwards (based on the prefix folder names).

# ========= CONFIG =========
SRC_BUCKET="${SRC_BUCKET:-tf-eu-west-2-hmpps-delius-pre-prod-alfresco-storage-s3bucket}"
DEST_BUCKET="${DEST_BUCKET:-cloud-platform-f0ef56cb1ce77f028f850c05f6691d6d}"
REGION="${AWS_REGION:-eu-west-2}"

# Cutoff (strictly "later than" this date/time)
CUTOFF_Y="${CUTOFF_Y:-2025}"
CUTOFF_M="${CUTOFF_M:-8}"
CUTOFF_D="${CUTOFF_D:-12}"
CUTOFF_H="${CUTOFF_H:-11}"
CUTOFF_MIN="${CUTOFF_MIN:-36}"

# Modes:
#   ALL_VERSIONS=0 (default) -> copy current versions only (fast)
#   ALL_VERSIONS=1           -> copy every version (slow)
ALL_VERSIONS="${ALL_VERSIONS:-0}"

# Set DRY_RUN=1 to preview operations
DRY_RUN="${DRY_RUN:-1}"

# Logging
LOGFILE="${LOGFILE:-./copy-after-cutoff.$(date +%Y%m%d-%H%M%S).log}"
AWS_PAGER=""  # disable aws pager

log() { printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE" >&2; }
req() { command -v "$1" >/dev/null || { log "ERROR: required command '$1' not found"; exit 1; }; }

req aws; req jq; req sed; req basename

tuple_cmp() {
  local a=("$1" "$2" "$3" "$4" "$5")
  local b=("$6" "$7" "$8" "$9" "${10}")
  for i in {0..4}; do
    if   (( a[i] > b[i] )); then echo 1; return
    elif (( a[i] < b[i] )); then echo -1; return
    fi
  done
  echo 0
}

list_children() {
  local bucket="$1" parent="$2"
  aws s3api list-objects-v2 \
    --bucket "$bucket" \
    --region "$REGION" \
    --prefix "$parent" \
    --delimiter '/' \
    --query 'CommonPrefixes[].Prefix' \
    --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d'
}

seg_num() { basename "$1" | sed 's:/$::'; }

copy_prefix_current() {
  local src_prefix="$1" dest_prefix="$2"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY-RUN] Would sync: s3://$SRC_BUCKET/$src_prefix -> s3://$DEST_BUCKET/$dest_prefix ${SIZE_ONLY:+--size-only} ${DELETE:+--delete}"
  else
    log "Syncing: s3://$SRC_BUCKET/$src_prefix -> s3://$DEST_BUCKET/$dest_prefix"
    # Add --size-only if you want to ignore timestamp/metadata differences
    aws s3 sync \
      "s3://$SRC_BUCKET/$src_prefix" \
      "s3://$DEST_BUCKET/$dest_prefix" \
      --only-show-errors \
      --region "$REGION" \
      ${SIZE_ONLY:+--size-only} \
      ${DELETE:+--delete} | tee -a "$LOGFILE"
  fi
}

copy_prefix_all_versions() {
  local src_prefix="$1" dest_prefix="$2"
  log "Enumerating versions under s3://$SRC_BUCKET/$src_prefix"
  local token="" total=0
  while :; do
    local page
    if [[ -n "$token" ]]; then
      page=$(aws s3api list-object-versions \
        --bucket "$SRC_BUCKET" --region "$REGION" \
        --prefix "$src_prefix" --starting-token "$token")
    else
      page=$(aws s3api list-object-versions \
        --bucket "$SRC_BUCKET" --region "$REGION" \
        --prefix "$src_prefix")
    fi

    # Build list of {Key,VersionId} for both Versions and DeleteMarkers (we cannot copy delete markers faithfully)
    versions=$(jq -c '[ (.Versions[]? | {Key:.Key, VersionId:.VersionId}) ]' <<<"$page")
    count=$(jq 'length' <<<"$versions")
    (( total += count ))

    if (( count > 0 )); then
      # Copy each version one by one
      # Note: destination will contain a new version for each copy; timestamps/etag/storage-class are preserved by S3,
      # but "LastModified" will reflect the time the version was created in DEST (you cannot backdate).
      while IFS= read -r item; do
        key=$(jq -r '.Key' <<<"$item")
        vid=$(jq -r '.VersionId' <<<"$item")
        # map the destination key 1:1
        dest_key="$key"
        # Replace the leading src_prefix with dest_prefix if they differ
        if [[ "$dest_prefix" != "$src_prefix" ]]; then
          dest_key="${dest_key#$src_prefix}"
          dest_key="$dest_prefix$dest_key"
        fi

        if [[ "$DRY_RUN" == "1" ]]; then
          log "[DRY-RUN] Would copy version: s3://$SRC_BUCKET/$key?versionId=$vid -> s3://$DEST_BUCKET/$dest_key"
        else
          aws s3api copy-object \
            --copy-source "$(printf '%s/%s?versionId=%s' "$SRC_BUCKET" "$key" "$vid")" \
            --bucket "$DEST_BUCKET" \
            --key "$dest_key" \
            --region "$REGION" \
            --metadata-directive COPY >/dev/null
          log "Copied version: $key (versionId=$vid) -> s3://$DEST_BUCKET/$dest_key"
        fi
      done < <(jq -c '.[]' <<<"$versions")
    fi

    token=$(jq -r '.NextToken // empty' <<<"$page")
    [[ -n "$token" ]] || break
  done
  log "Finished copying versions under '$src_prefix' (versions copied: $total)"
}

process_prefix() {
  local src_prefix="$1"
  local dest_prefix="$1"   # mirror structure by default
  if [[ "$ALL_VERSIONS" == "1" ]]; then
    copy_prefix_all_versions "$src_prefix" "$dest_prefix"
  else
    copy_prefix_current "$src_prefix" "$dest_prefix"
  fi
}

traverse_and_copy() {
  local p_year="$1" p_month="$2" p_day="$3" p_hour="$4" p_min="$5" base="$6"

  # years
  if [[ -z "$base" ]]; then
    for ypref in $(list_children "$SRC_BUCKET" ""); do
      y=$(seg_num "$ypref"); [[ "$y" =~ ^[0-9]+$ ]] || continue
      cmp=$(tuple_cmp "$y" 0 0 0 0 "$CUTOFF_Y" 0 0 0 0)
      if (( cmp == 1 )); then
        process_prefix "$ypref"
      elif (( cmp == 0 )); then
        traverse_and_copy "$y" 0 0 0 0 "$ypref"
      fi
    done
    return
  fi

  # months
  if [[ "$p_month" -eq 0 ]]; then
    for mpref in $(list_children "$SRC_BUCKET" "$base"); do
      m=$(seg_num "$mpref"); [[ "$m" =~ ^[0-9]+$ ]] || continue
      cmp=$(tuple_cmp "$p_year" "$m" 0 0 0 "$CUTOFF_Y" "$CUTOFF_M" 0 0 0)
      if (( cmp == 1 )); then
        process_prefix "$mpref"
      elif (( cmp == 0 )); then
        traverse_and_copy "$p_year" "$m" 0 0 0 "$mpref"
      fi
    done
    return
  fi

  # days
  if [[ "$p_day" -eq 0 ]]; then
    for dpref in $(list_children "$SRC_BUCKET" "$base"); do
      d=$(seg_num "$dpref"); [[ "$d" =~ ^[0-9]+$ ]] || continue
      cmp=$(tuple_cmp "$p_year" "$p_month" "$d" 0 0 "$CUTOFF_Y" "$CUTOFF_M" "$CUTOFF_D" 0 0)
      if (( cmp == 1 )); then
        process_prefix "$dpref"
      elif (( cmp == 0 )); then
        traverse_and_copy "$p_year" "$p_month" "$d" 0 0 "$dpref"
      fi
    done
    return
  fi

  # hours
  if [[ "$p_hour" -eq 0 ]]; then
    for hpref in $(list_children "$SRC_BUCKET" "$base"); do
      h=$(seg_num "$hpref"); [[ "$h" =~ ^[0-9]+$ ]] || continue
      cmp=$(tuple_cmp "$p_year" "$p_month" "$p_day" "$h" 0 "$CUTOFF_Y" "$CUTOFF_M" "$CUTOFF_D" "$CUTOFF_H" 0)
      if (( cmp == 1 )); then
        process_prefix "$hpref"
      elif (( cmp == 0 )); then
        traverse_and_copy "$p_year" "$p_month" "$p_day" "$h" 0 "$hpref"
      fi
    done
    return
  fi

  # minutes (leaf)
  for minpref in $(list_children "$SRC_BUCKET" "$base"); do
    mm=$(seg_num "$minpref"); [[ "$mm" =~ ^[0-9]+$ ]] || continue
    cmp=$(tuple_cmp "$p_year" "$p_month" "$p_day" "$p_hour" "$mm" \
                     "$CUTOFF_Y" "$CUTOFF_M" "$CUTOFF_D" "$CUTOFF_H" "$CUTOFF_MIN")
    if (( cmp == 1 )); then
      process_prefix "$minpref"
    fi
  done
}

log "Source:      s3://$SRC_BUCKET"
log "Destination: s3://$DEST_BUCKET"
log "Region:      $REGION"
log "Cutoff (>):  $CUTOFF_Y/$CUTOFF_M/$CUTOFF_D/$CUTOFF_H/$CUTOFF_MIN"
log "Mode:        $([[ "$ALL_VERSIONS" == "1" ]] && echo "ALL_VERSIONS" || echo "CURRENT ONLY")"
[[ "$DRY_RUN" == "1" ]] && log "DRY-RUN enabled (set DRY_RUN=0 to execute)"

traverse_and_copy 0 0 0 0 0 ""
log "Done."

