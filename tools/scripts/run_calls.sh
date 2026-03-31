#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Your actual pod names
# -----------------------------
POD_A="alfresco-content-services-alfresco-repository-7c855574d-dmk4q"
POD_B="alfresco-content-services-alfresco-repository-7c855574d-pdpz6"

# -----------------------------
# Required variables
# -----------------------------
NODE_ID="5b7112aa-e4ff-4372-a6fc-e0dc04e0ca33"                       # Pass UUID on command line
ALF_USER="${ALF_USER:-admin}"
ALF_PASS="${ALF_PASS:-admin}"
NAMESPACE="hmpps-delius-alfresco-poc"
TIMEOUT_SEC="${TIMEOUT_SEC:-90}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

if [[ -z "$NODE_ID" ]]; then
  echo "Usage: ./lock-test.sh <NODE_UUID>"
  exit 1
fi

kexec() {
  kubectl exec -n "$NAMESPACE" -it "$1" -- bash -lc "$2"
}

api_lock() {
  kexec "$1" \
    "curl -s -u '${ALF_USER}:${ALF_PASS}' -X POST \
     -H 'Content-Type: application/json' \
     'http://localhost:8080/alfresco/api/-default-/public/alfresco/versions/1/nodes/${NODE_ID}/lock' \
     -d '{\"lifetime\":\"PERSISTENT\",\"type\":\"WRITE_LOCK\"}'"
}

api_get_node() {
  kexec "$1" \
    "curl -s -u '${ALF_USER}:${ALF_PASS}' \
     'http://localhost:8080/alfresco/api/-default-/public/alfresco/versions/1/nodes/${NODE_ID}'"
}

extract_is_locked() {
  if grep -q '"isLocked"[[:space:]]*:[[:space:]]*true' <<<"$1"; then
    echo "true"
  else
    echo "false"
  fi
}

timestamp_ms() {
  date +%s%3N 2>/dev/null || python3 - <<'EOF'
import time; print(int(time.time()*1000))
EOF
}

echo "Locking node $NODE_ID on $POD_A ..."
LOCK_START_MS="$(timestamp_ms)"
LOCK_RESP="$(api_lock "$POD_A")"
LOCK_END_MS="$(timestamp_ms)"

echo "Lock response:"
echo "$LOCK_RESP"
echo

echo "Reading immediately from $POD_B ..."
IMMEDIATE_JSON="$(api_get_node "$POD_B")"
IS_LOCKED_IMMEDIATE="$(extract_is_locked "$IMMEDIATE_JSON")"

echo "Pod B immediate isLocked=$IS_LOCKED_IMMEDIATE"
echo "$IMMEDIATE_JSON"
echo

echo "Polling Pod B for lock propagation..."
SECS=0

while (( SECS < TIMEOUT_SEC )); do
  sleep "$POLL_INTERVAL"
  SECS=$((SECS + POLL_INTERVAL))
  JSON="$(api_get_node "$POD_B")"
  CURR="$(extract_is_locked "$JSON")"
  echo "t=+${SECS}s → isLocked=$CURR"

  if [[ "$CURR" == "true" ]]; then
    NOW_MS="$(timestamp_ms)"
    DELAY_MS=$((NOW_MS - LOCK_START_MS))
    echo "✔ Lock visible on Pod B after ~$((DELAY_MS/1000)) seconds."
    exit 0
  fi
done

echo "⚠ Timed out after ${TIMEOUT_SEC}s — Pod B did not update its lock state."
exit 1