#!/bin/bash
# amq-wait-empty.sh
# Usage: ./amq-wait-empty.sh <queue_name> <stat> [namespace] [interval_secs]
# Example: ./amq-wait-empty.sh acs-repo-transform-request size preprod 30

set -euo pipefail

QUEUE_NAME=${1:?Usage: $0 <queue_name> <stat> [namespace] [interval_secs]}
STAT=${2:?Usage: $0 <queue_name> <stat> [namespace] [interval_secs]}
NAMESPACE=${3:-}
INTERVAL=${4:-30}

if [[ -n "$NAMESPACE" ]]; then
  NS_ARG="$NAMESPACE"
else
  NS_ARG=""
fi

get_total() {
  # relies on your existing amq-totals.sh output format
  ./amq-totals.sh "$QUEUE_NAME" "$STAT" "$NS_ARG" \
    | awk '/^Total messages in stat/{print $NF}'
}

prev_total=""
prev_ts=""

while true; do
  now_ts=$(date +%s)
  total=$(get_total)

  # Basic validation
  if ! [[ "$total" =~ ^[0-9]+$ ]]; then
    echo "[$(date '+%F %T')] Unable to parse total (got: '$total'). Retrying in $INTERVAL s..."
    sleep "$INTERVAL"
    continue
  fi

  line="[$(date '+%F %T')] $QUEUE_NAME ($STAT): total=$total"

  if [[ -n "${prev_total}" ]]; then
    elapsed=$(( now_ts - prev_ts ))
    (( elapsed == 0 )) && elapsed=1  # avoid div by zero

    delta=$(( total - prev_total ))  # positive = growing, negative = draining
    # rate per second (float)
    rate_per_sec=$(awk -v d="$delta" -v e="$elapsed" 'BEGIN{printf "%.2f", d/e}')
    # per-minute helper too
    rate_per_min=$(awk -v r="$rate_per_sec" 'BEGIN{printf "%.1f", r*60}')
    # per-hour helper too
    rate_per_hour=$(awk -v r="$rate_per_sec" 'BEGIN{printf "%.1f", r*3600}')

    symbol="↔"
    [[ $delta -gt 0 ]] && symbol="↑"
    [[ $delta -lt 0 ]] && symbol="↓"

    line+=" | Δ=${delta} in ${elapsed}s ${symbol}  rate=${rate_per_sec}/s (${rate_per_min}/min ${rate_per_hour}/hr)"

    # ETA if draining (negative rate)
    if awk -v r="$rate_per_sec" 'BEGIN{exit !(r<0)}'; then
      # eta = total / -rate
      eta_sec=$(awk -v t="$total" -v r="$rate_per_sec" 'BEGIN{printf "%.0f", t/(-r)}')
      # Pretty ETA
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

  echo "$line"

  if [[ "$total" -eq 0 ]]; then
    echo "Queue is empty."
    osascript -e 'tell application "System Events" to display dialog "Queue is empty." with title "Alert Box"'
    exit 0
  fi

  prev_total="$total"
  prev_ts="$now_ts"
  sleep "$INTERVAL"
done