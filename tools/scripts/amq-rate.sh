#!/bin/bash
# amq-rate.sh
# Usage: ./amq-rate.sh <env> <queue_name> <stop_stat> [interval_secs]
# Example: ./amq-rate.sh dev acs-repo-transform-request size preprod 30
# - <stop_stat> is usually 'size'. The rate is always computed from dequeueCount.
# This is a simpler version of amq-wait-empty.sh that just prints the rate and doesn't wait for the queue to empty.

set -euo pipefail

env=$1
QUEUE_NAME=${2:-"acs-repo-transform-request"}
STOP_STAT=${3:-"size"}
INTERVAL=${4:-30}

if [[ "$env" != "poc" && "$env" != "dev" && "$env" != "test" && "$env" != "stage" && "$env" != "preprod" && "$env" != "prod" ]]; then
    log_error "Invalid namespace. Allowed values: poc, dev, test, stage, preprod or prod."
    exit 1
fi

get_total_for() {
  local stat="$1"
  ./amq-totals.sh "$env" "$QUEUE_NAME" "$stat" \
    | awk '/^Total messages in stat/{print $NF}'
}

prev_deq=""
prev_ts=""

while true; do
  now_ts=$(date +%s)

  # Check the stop stat (usually 'size') and the dequeueCount for rate
  size_total=$(get_total_for "$STOP_STAT")
  deq_total=$(get_total_for "dequeueCount")

  # Validation
  if ! [[ "$size_total" =~ ^[0-9]+$ ]] || ! [[ "$deq_total" =~ ^[0-9]+$ ]]; then
    echo "[$(date '+%F %T')] Parse error (size='$size_total', dequeueCount='$deq_total'). Retrying in $INTERVAL s…"
    sleep "$INTERVAL"
    continue
  fi

  line="[$(date '+%F %T')] $QUEUE_NAME: $STOP_STAT=$size_total"

  if [[ -n "$prev_deq" ]]; then
    elapsed=$(( now_ts - prev_ts ))
    (( elapsed == 0 )) && elapsed=1

    delta_deq=$(( deq_total - prev_deq ))          # msgs processed since last check
    rate_per_sec=$(awk -v d="$delta_deq" -v e="$elapsed" 'BEGIN{printf "%.2f", d/e}')
    rate_per_min=$(awk -v r="$rate_per_sec" 'BEGIN{printf "%.1f", r*60}')
    rate_per_hour=$(awk -v r="$rate_per_sec" 'BEGIN{printf "%.1f", r*3600}')

    line+=" | processed Δ=${delta_deq} in ${elapsed}s  rate=${rate_per_sec}/s (${rate_per_min}/min) (${rate_per_hour}/hour)"

    # ETA only if we are actually draining (positive processing rate)
    if awk -v r="$rate_per_sec" 'BEGIN{exit !(r>0)}'; then
      if (( size_total > 0 )); then
        eta_sec=$(awk -v t="$size_total" -v r="$rate_per_sec" 'BEGIN{printf "%.0f", (r>0)? t/r : 0}')
        if (( eta_sec > 0 )); then
          if (( eta_sec < 3600 )); then
            eta_str="$(awk -v s="$eta_sec" 'BEGIN{printf "%dm%02ds", int(s/60), int(s%60)}')"
          else
            eta_str="$(awk -v s="$eta_sec" 'BEGIN{printf "%dh%02dm%02ds", int(s/3600), int((s%3600)/60), int(s%60)}')"
          fi
          line+=" | ETA≈${eta_str}"
        fi
      fi
    fi
  fi

  echo "$line"

  prev_deq="$deq_total"
  prev_ts="$now_ts"
  sleep "$INTERVAL"
done