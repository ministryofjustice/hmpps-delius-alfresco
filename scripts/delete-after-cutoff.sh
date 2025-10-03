#!/usr/bin/env bash
set -euo pipefail

# This script is used for the CP migration to delete objects from the S3 bucket 
# from a particular point in time forwards (based on the prefix folder names).

# ======= CONFIG =======
BUCKET="${BUCKET:-cloud-platform-f0ef56cb1ce77f028f850c05f6691d6d}"
REGION="${AWS_REGION:-eu-west-2}"

# Cutoff (strictly "later than" this date/time)
CUTOFF_Y="${CUTOFF_Y:-2025}"
CUTOFF_M="${CUTOFF_M:-8}"
CUTOFF_D="${CUTOFF_D:-12}"
CUTOFF_H="${CUTOFF_H:-11}"
CUTOFF_MIN="${CUTOFF_MIN:-36}"

# Dry-run by default; set to 0 to actually delete
DRY_RUN="${DRY_RUN:-1}"

# Log file (in-container). You'll see logs in both stdout and this file.
LOGFILE="${LOGFILE:-/home/job/delete-after-cutoff.log}"

# Make AWS CLI non-interactive (no pager)
export AWS_PAGER=""

# ======= LOGGING =======
log() {
  # timestamped line to stderr and to file
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE" >&2
}

# ======= REQUIREMENTS =======
command -v aws >/dev/null || { log "aws CLI not found"; exit 1; }
command -v jq  >/dev/null || { log "jq not found"; exit 1; }

# Compare two timestamp tuples (y m d h min). Echo 1 if A>B, 0 if A==B, -1 if A<B
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

delete_prefix_versions() {
  local prefix="$1"
  log "Preparing delete for all versions under s3://$BUCKET/$prefix"

  local token=""
  local total=0
  while :; do
    local page
    if [[ -n "$token" ]]; then
      page=$(aws s3api list-object-versions \
        --bucket "$BUCKET" \
        --region "$REGION" \
        --prefix "$prefix" \
        --starting-token "$token")
    else
      page=$(aws s3api list-object-versions \
        --bucket "$BUCKET" \
        --region "$REGION" \
        --prefix "$prefix")
    fi

    local objs
    objs=$(jq -c '[ ( .Versions[]? | {Key:.Key, VersionId:.VersionId} ),
                     ( .DeleteMarkers[]? | {Key:.Key, VersionId:.VersionId} ) ]' <<<"$page")
    local count
    count=$(jq 'length' <<<"$objs")
    (( total += count ))

    if (( count > 0 )); then
      for batch_idx in $(jq -r 'range(0; length; 1000)' <<<"$objs"); do
        local batch payload
        batch=$(jq -c ".[$batch_idx : ($batch_idx+1000)]" <<<"$objs")
        payload=$(jq -c '{Objects: ., Quiet: true}' <<<"$batch")

        if [[ "$DRY_RUN" == "1" ]]; then
          log "[DRY-RUN] Would delete $(jq 'length' <<<"$batch") versions from prefix '$prefix'"
        else
          aws s3api delete-objects \
            --bucket "$BUCKET" \
            --region "$REGION" \
            --delete "$payload" >/dev/null
          log "Deleted $(jq 'length' <<<"$batch") versions from '$prefix'"
        fi
      done
    fi

    token=$(jq -r '.NextToken // empty' <<<"$page")
    [[ -n "$token" ]] || break
  done

  log "Finished prefix '$prefix' (versions+markers: $total)"
}

list_children() {
  local parent="$1"
  aws s3api list-objects-v2 \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --prefix "$parent" \
    --delimiter '/' \
    --query 'CommonPrefixes[].Prefix' \
    --output text 2>/dev/null | tr '\\t' '\\n' | sed '/^$/d'
}

seg_num() { basename "$1" | sed 's:/$::'; }

traverse_and_delete() {
  local p_year="$1" p_month="$2" p_day="$3" p_hour="$4" p_min="$5" base="$6"

  case "$base" in
    "")
       for ypref in $(list_children ""); do
         y=$(seg_num "$ypref"); [[ "$y" =~ ^[0-9]+$ ]] || continue
         cmp=$(tuple_cmp "$y" 0 0 0 0 "$CUTOFF_Y" 0 0 0 0)
         if (( cmp == 1 )); then
           delete_prefix_versions "$ypref"
         elif (( cmp == 0 )); then
           traverse_and_delete "$y" 0 0 0 0 "$ypref"
         fi
       done
       return
       ;;
  esac

  if [[ -n "$base" && "$p_month" -eq 0 ]]; then
    for mpref in $(list_children "$base"); do
      m=$(seg_num "$mpref"); [[ "$m" =~ ^[0-9]+$ ]] || continue
      cmp=$(tuple_cmp "$p_year" "$m" 0 0 0 "$CUTOFF_Y" "$CUTOFF_M" 0 0 0)
      if (( cmp == 1 )); then
        delete_prefix_versions "$mpref"
      elif (( cmp == 0 )); then
        traverse_and_delete "$p_year" "$m" 0 0 0 "$mpref"
      fi
    done
    return
  fi

  if [[ "$p_day" -eq 0 ]]; then
    for dpref in $(list_children "$base"); do
      d=$(seg_num "$dpref"); [[ "$d" =~ ^[0-9]+$ ]] || continue
      cmp=$(tuple_cmp "$p_year" "$p_month" "$d" 0 0 "$CUTOFF_Y" "$CUTOFF_M" "$CUTOFF_D" 0 0)
      if (( cmp == 1 )); then
        delete_prefix_versions "$dpref"
      elif (( cmp == 0 )); then
        traverse_and_delete "$p_year" "$p_month" "$d" 0 0 "$dpref"
      fi
    done
    return
  fi

  if [[ "$p_hour" -eq 0 ]]; then
    for hpref in $(list_children "$base"); do
      h=$(seg_num "$hpref"); [[ "$h" =~ ^[0-9]+$ ]] || continue
      cmp=$(tuple_cmp "$p_year" "$p_month" "$p_day" "$h" 0 "$CUTOFF_Y" "$CUTOFF_M" "$CUTOFF_D" "$CUTOFF_H" 0)
      if (( cmp == 1 )); then
        delete_prefix_versions "$hpref"
      elif (( cmp == 0 )); then
        traverse_and_delete "$p_year" "$p_month" "$p_day" "$h" 0 "$hpref"
      fi
    done
    return
  fi

  for minpref in $(list_children "$base"); do
    mm=$(seg_num "$minpref"); [[ "$mm" =~ ^[0-9]+$ ]] || continue
    cmp=$(tuple_cmp "$p_year" "$p_month" "$p_day" "$p_hour" "$mm" \
                     "$CUTOFF_Y" "$CUTOFF_M" "$CUTOFF_D" "$CUTOFF_H" "$CUTOFF_MIN")
    if (( cmp == 1 )); then
      delete_prefix_versions "$minpref"
    fi
  done
}

log "Bucket: $BUCKET (region: $REGION)"
log "Cutoff (strictly greater than): $CUTOFF_Y/$CUTOFF_M/$CUTOFF_D/$CUTOFF_H/$CUTOFF_MIN"
[[ "$DRY_RUN" == "1" ]] && log "Mode: DRY-RUN (set DRY_RUN=0 to actually delete)"

traverse_and_delete 0 0 0 0 0 ""
log "Done."
