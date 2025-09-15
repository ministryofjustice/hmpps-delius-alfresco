#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Batch Alfresco → OpenSearch reindex runner (descending by child_node_id)
# -----------------------------------------------------------------------------
# What this script does
#  1) Rebuilds hierarchy by reindexing id range 0..1000 (once).
#  2) Reindexes all children of a specific parent (parent_node_id=738) one-by-one
#     using FROM=child_node_id and TO=child_node_id+1 (once).
#  3) Then iterates in batches of BATCH_SIZE=100000 documents, starting from the
#     latest (highest child_node_id where type_qname_id=35), going downward.
#  4) After each batch, waits for AMQ queue (acs-repo-transform-request) to drain
#     below QUEUE_THRESHOLD (≈5000) before triggering the next batch.
#  5) To avoid stale ports/tunnels, it re-establishes fresh port-forwards for RDS
#     and AMQ at each point of use using your existing helper scripts if present.
#
# Requirements (expected to be available in PATH):
#   - task                       (Taskfile runner for reindex_by_id)
#   - psql                       (PostgreSQL client e.g. brew install libpq)
#   - kubectl, timeout, awk, sed, tr, date
#   - ./rds-connect.sh           (your helper: establishes/refreshes DB port-forward)
#   - ./amq-connect-single.sh    (your helper: establishes/refreshes AMQ port-forward)
#   - ./amq-wait-empty.sh        (your helper: waits until AMQ queue empties or below threshold)
#
# Notes:
#   * This script is restartable: it stores progress in STATE_FILE, so you can
#     rerun it and it will resume from the previous min_id.
#   * It purposely re-creates the port-forwarding sessions right before DB/AMQ
#     work to ensure fresh connections for long runs.
# -----------------------------------------------------------------------------

# ----------------------------- Configurable bits ------------------------------
STARTING_NODE_ID=790534185
ENV_NAME="preprod"
K8S_NAMESPACE="hmpps-delius-alfresco-preprod"
BATCH_SIZE=100000

PARENT_NODE_ID_FOR_CHILDREN=738
TYPE_QNAME_ID_FOR_DOCS=35
STATE_FILE=".reindex_state.descending.json"
# Label selector or name filter to locate the utils pod
UTILS_SELECTOR="-l app=utils"

# Values for checking the queue in Amazon MQ
AMQ_BROKER_URL=$(kubectl get secrets amazon-mq-broker-secret -o json | jq -r ".data.BROKER_CONSOLE_URL | @base64d")
AMQ_BROKER_USER=$(kubectl get secret amazon-mq-broker-secret -o json | jq -r ".data | map_values(@base64d) | .BROKER_USERNAME")
AMQ_BROKER_PASSWORD=$(kubectl get secret amazon-mq-broker-secret -o json | jq -r ".data | map_values(@base64d) | .BROKER_PASSWORD")
AMQ_QUEUE_NAME="acs-repo-transform-request"
AMQ_QUEUE_STAT="size"

QUEUE_THRESHOLD=5000           # proceed when queue size <= this
INITIAL_QUEUE_SETTLE_SEC=240   # allow time after batch for queue to start filling
QUEUE_WAIT_TIMEOUT_SEC=$((60*50)) # max wait ~50 minutes per batch

# ----------------------------- Helper functions -------------------------------
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2; }

fatal() { log "FATAL: $*"; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_tools() {
  for c in task psql kubectl awk sed tr; do
    have_cmd "$c" || fatal "Missing required command: $c"
  done
}

# Metrics helpers ---------------------------------------------------------------
metrics_header_if_needed() {
  if [[ ! -f "$METRICS_CSV" ]]; then
    echo "phase,from_id,to_id,doc_count,batch_started_at,batch_finished_at,batch_duration_sec,queue_wait_sec" > "$METRICS_CSV"
  fi
}

metrics_append() {
  local phase=$1 from_id=$2 to_id=$3 count=$4 start_iso=$5 finish_iso=$6 duration=$7 queue_wait=$8
  metrics_header_if_needed
  echo "$phase,$from_id,$to_id,$count,$start_iso,$finish_iso,$duration,$queue_wait" >> "$METRICS_CSV"
}

# Retry wrapper for kubectl
kubectl_retry() {
  local max_retries=5
  local delay=10
  local attempt=1

  while true; do
    if kubectl "$@"; then
      return 0
    fi

    echo "kubectl command failed (attempt $attempt/$max_retries): kubectl $*" >&2
    if [ "$attempt" -ge "$max_retries" ]; then
      echo "Giving up after $max_retries attempts" >&2
      return 1
    fi

    attempt=$((attempt+1))
    sleep $delay
  done
}

get_utils_pod() {
  # First try a label selector
  local pod
  pod=$(kubectl_retry -n "$K8S_NAMESPACE" get pods $UTILS_SELECTOR -o name 2>/dev/null | head -n1 | cut -d/ -f2)
  if [[ -z "$pod" ]]; then
    # Fallback: grep for 'utils' in pod names
    pod=$(kubectl_retry -n "$K8S_NAMESPACE" get pods --no-headers -o custom-columns=":metadata.name" | grep -m1 -E 'utils' || true)
  fi
  echo "$pod"
}

# Run a SQL query and echo rows (tab-separated, unaligned) to stdout
sql() {
  query="$1"
  local pod; pod=$(get_utils_pod)
  [[ -z "$pod" ]] && fatal "Could not locate a 'utils' pod in namespace $K8S_NAMESPACE"

  local tmpfile; tmpfile=$(mktemp)
  cat >"$tmpfile" <<EOF
#!/usr/bin/env bash
[[ -f /etc/profile.d/psql-utils.sh ]] && . /etc/profile.d/psql-utils.sh || true
result=\$(psqlr --tuples-only --no-align -c "${query}")
echo \$result
EOF

  local remote="/tmp/run-sql-test.sh"
  kubectl cp "$tmpfile" "$pod":"$remote"
  rm -f "$tmpfile"
  result=$(kubectl exec "$pod" -- bash -lc "chmod +x '$remote' && '$remote' && rm -f '$remote'")
  echo $result
}

amq() {
  local pod; pod=$(get_utils_pod)
  [[ -z "$pod" ]] && fatal "Could not locate a 'utils' pod in namespace $K8S_NAMESPACE"
  local tmpfile=$(mktemp)
  cat >"$tmpfile" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ -f /etc/profile.d/utils-profile.sh ]] && . /etc/profile.d/utils-profile.sh || true
xml_url="${AMQ_BROKER_URL}/admin/xml/queues.jsp"
xml_data="\$(curl -s -k --user '${AMQ_BROKER_USER}:${AMQ_BROKER_PASSWORD}' "\$xml_url")"
echo "\${xml_data:-0}"
EOF

  local remote="/tmp/run-curl.sh"
  kubectl cp "$tmpfile" "$pod":"$remote"
  rm -f "$tmpfile"
  xml_data=$(kubectl exec "$pod" -- bash -lc "chmod +x '$remote' && '$remote' && rm -f '$remote'")
  # Do the xmllint locally as it's not installed in the utils pod
  queue_size=$(echo "$xml_data" | xmllint --xpath "string(//queue[@name='${AMQ_QUEUE_NAME}']/stats/@${AMQ_QUEUE_STAT})" -)
  echo "${queue_size:-0}"
}

# Wait until the AMQ queue is at or below QUEUE_THRESHOLD
wait_queue_below_threshold() {
  log "Waiting ${INITIAL_QUEUE_SETTLE_SEC}s for queue to start filling after batch …"
  sleep "${INITIAL_QUEUE_SETTLE_SEC}"
  
  local start_ts now count
  start_ts=$(date +%s)

  while true; do
    # Get current queue size via amq(); handle transient failures
    if ! count="$(amq 2>/dev/null)"; then
      log "WARN: amq() failed to fetch queue size; retrying in 15s …"
      sleep 15
      continue
    fi

    # Normalize and log
    log "Queue ${AMQ_QUEUE_NAME} ≈ ${count} messages … (target ≤ ${QUEUE_THRESHOLD})"

    # Proceed when threshold reached
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count <= QUEUE_THRESHOLD )); then
      break
    fi

    # Timeout guard
    now=$(date +%s)
    if (( now - start_ts > QUEUE_WAIT_TIMEOUT_SEC )); then
      fatal "Queue did not drop below ${QUEUE_THRESHOLD} within ${QUEUE_WAIT_TIMEOUT_SEC}s (last count=${count})"
    fi

    sleep 30
  done

  echo $(( $(date +%s) - start_ts ))
}

# Emit and run a single task reindex_by_id invocation
run_reindex_task() {
  local from_id=$1
  local to_id=$2
  log "Launching: task reindex_by_id ENV=${ENV_NAME} FROM=${from_id} TO=${to_id} …"
  task reindex_by_id ENV="${ENV_NAME}" FROM="${from_id}" TO="${to_id}"
}

# State management (JSON stored very simply without jq to avoid dependency)
write_state() {
  local next_max=$1
  printf '{"next_max_id":%s,"updated":"%s"}\n' "$next_max" "$(date -Iseconds)" >"${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "${STATE_FILE}"
}

read_state_or_empty() {
  if [[ -f "${STATE_FILE}" ]]; then
    awk -F '[,:}]' '/next_max_id/{gsub(/[^0-9]/, "", $2); print $2}' "${STATE_FILE}" | head -n1
  else
    echo ""
  fi
}

# ---- Fix for parsing batch window output ----
# When reading values separated by '|' rather than tabs
parse_batch_row() {
  local row="$1"
  local min_id window_max count
  IFS='|' read -r min_id window_max count <<<"$row"
  echo "$min_id $window_max $count"
}

# ---------------------------- Phase 1: hierarchy ------------------------------
phase_hierarchy() {
  log "Phase 1: Reindex hierarchy ids 0..1000"
  run_reindex_task 0 1000
}

# ---------------------- Phase 2: specific parent children ---------------------
phase_parent_children() {
  log "Phase 2: Reindex all children of parent_node_id=${PARENT_NODE_ID_FOR_CHILDREN}"
  local q="SELECT aca.child_node_id, aca.child_node_id+1 AS to_id\n          FROM alf_child_assoc aca\n          WHERE aca.parent_node_id = ${PARENT_NODE_ID_FOR_CHILDREN}\n          ORDER BY aca.child_node_id ASC;"
  while IFS=$'\t' read -r from_id to_id; do
    [[ -z "$from_id" || -z "$to_id" ]] && continue
    log "Reindexing children of parent_node_id=${PARENT_NODE_ID_FOR_CHILDREN}: FROM=${from_id} TO=${to_id}"
    run_reindex_task "$from_id" "$to_id"
  done < <(sql "$q")
}

# ---------------------- Phase 3: batched descending loop ----------------------
# returns the MIN/MAX child_node_id for next batch window starting from given max
calc_batch_window() {
  local current_max_id=$1
  local q="WITH limited AS (SELECT child_node_id FROM alf_child_assoc WHERE type_qname_id = ${TYPE_QNAME_ID_FOR_DOCS} AND child_node_id <= ${current_max_id} ORDER BY child_node_id DESC LIMIT ${BATCH_SIZE}) SELECT MIN(child_node_id) AS min_id, MAX(child_node_id) AS max_id, COUNT(*) FROM limited;"
  sql "$q"
}

get_max_child_id() {
  # if STARTING_NODE_ID is set them use the below sql with restriction on child_node_id
  if [[ -n "$STARTING_NODE_ID" ]]; then
    local q="SELECT COALESCE(MAX(child_node_id),0) FROM alf_child_assoc WHERE type_qname_id=${TYPE_QNAME_ID_FOR_DOCS} and child_node_id = ${STARTING_NODE_ID};"
  else
    local q="SELECT COALESCE(MAX(child_node_id),0) FROM alf_child_assoc WHERE type_qname_id=${TYPE_QNAME_ID_FOR_DOCS};"
  fi
  sql "$q"
}

phase_descending_batches() {
  log "Phase 3: Descending batches of ${BATCH_SIZE} (type_qname_id=${TYPE_QNAME_ID_FOR_DOCS})"

  local resume_max
  resume_max=$(read_state_or_empty)

  local max_id
  if [[ -n "$resume_max" ]]; then
    log "Resuming from saved next_max_id=${resume_max}"
    max_id=$resume_max
  else
    log "Fetching initial MAX(child_node_id) …"
    max_id=$(get_max_child_id)
  fi

  if [[ -z "$max_id" || ! "$max_id" =~ ^[0-9]+$ || "$max_id" -le 0 ]]; then
    log "Nothing to do (max_id=${max_id})."
    return 0
  else
    log "Starting from node id=${max_id}"
  fi

  while (( max_id > 0 )); do
    log "Computing window ≤ ${max_id} …"
    local row
    row=$(calc_batch_window "$max_id") || fatal "Failed to compute batch window"
    local min_id window_max count
    read min_id window_max count <<<"$(parse_batch_row "$row")"

    if [[ -z "$min_id" || -z "$window_max" || -z "$count" || "$count" -eq 0 ]]; then
      log "No more rows under max_id=${max_id}. Done."
      break
    fi

    log "Next batch: FROM=${min_id} TO=${window_max} (count=${count})"
    run_reindex_task "$min_id" "$window_max"

    wait_queue_below_threshold

    # Prepare for next window: use the previous min_id as new max bound
    max_id=$min_id
    write_state "$max_id"
  done

  log "All batches complete."
}

# ----------------------------------- Main -------------------------------------
main() {
  ensure_tools
  export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
  export KUBECTL_NAMESPACE_OVERRIDE="${K8S_NAMESPACE}"

  log "Starting reindex runner for ENV=${ENV_NAME} in namespace ${K8S_NAMESPACE} …"

  # Phase 1 & 2 should run only once; guard with simple sentinels
  if [[ ! -f .phase1.done ]]; then
    phase_hierarchy
    touch .phase1.done
  else
    log "Phase 1 already completed (marker .phase1.done exists)."
  fi

  if [[ ! -f .phase2.done ]]; then
    phase_parent_children
    touch .phase2.done
  else
    log "Phase 2 already completed (marker .phase2.done exists)."
  fi

  phase_descending_batches
}

main "$@"
