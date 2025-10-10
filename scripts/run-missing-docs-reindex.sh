#!/usr/bin/env bash
set -euo pipefail

# This script runs reindex jobs for all node_ids listed in the moj_os_missing_docs table.
# It throttles job creation to avoid exceeding the pod quota (100 pods total).
# It requires a 'utils' pod in the target namespace with psqlr and task installed

# Usage: ./run-missing-docs-reindex.sh <env>
# Example: ./run-missing-docs-reindex.sh prod
ENV_INPUT="${1:-prod}"
MAX_NODE_ID="${2:-}"  # optional max node_id to process (for testing)

# Compute namespace from env (special-case "poc" if you ever need it)
if [[ "${ENV_INPUT}" == "poc" ]]; then
  NS="hmpps-delius-alfrsco-${ENV_INPUT}"
else
  NS="hmpps-delius-alfresco-${ENV_INPUT}"
fi

if [[ -n "${MAX_NODE_ID}" && ! "${MAX_NODE_ID}" =~ ^[0-9]+$ ]]; then
  echo "Error: MAX_NODE_ID must be a positive integer" >&2
  exit 1
fi

if [[ -n "${MAX_NODE_ID}" ]]; then
  echo "Limiting to node_id <= ${MAX_NODE_ID}"
  WHERE_CLAUSE="WHERE NODE_ID <= ${MAX_NODE_ID}"
else
  WHERE_CLAUSE=""
fi

# Safety margin: EKS has a hard 100 pods quota; we leave 2 free for the app.
MAX_PODS=98

# Temp files
TMP_DIR="$(mktemp -d)"
IDS_FILE="${TMP_DIR}/node_ids.txt"
LOG_DIR="${TMP_DIR}/logs"
LOG_FILE="${LOG_DIR}/reindex-${ENV_INPUT}.log"
mkdir -p "${LOG_DIR}"

echo "Environment: ${ENV_INPUT}"
echo "Namespace:   ${NS}"
echo "Temp dir:    ${TMP_DIR}"

# ---- helpers ---------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

need kubectl
need awk
need tr
need wc
need sed
need task

# Find the utils pod (we deploy a 'utils' pod for DB tools)
get_utils_pod() {
  local pod
  # Prefer label selector if available
  pod="$(kubectl -n "${NS}" get pods -l app=utils -o name 2>/dev/null | head -n1 | cut -d/ -f2 || true)"
  if [[ -z "${pod}" ]]; then
    # Fallback: grep by name
    pod="$(kubectl -n "${NS}" get pods --no-headers -o custom-columns=":metadata.name" | grep -m1 -E 'utils' || true)"
  fi
  [[ -n "${pod}" ]] && printf "%s\n" "${pod}" || return 1
}

# Run SQL inside the utils pod using psqlr, then stream results to stdout
sql_in_utils() {
  local query="$1"
  local pod; pod="$(get_utils_pod)" || die "No utils pod found in namespace ${NS}"
  # Create a tiny runner script inside the pod so quoting is easy/safe
  kubectl -n "${NS}" exec "${pod}" -- bash -lc "cat >/tmp/run-sql.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
# Some images source profile files that set DB env + add psqlr to PATH
[[ -f /etc/profile.d/psql-utils.sh ]] && . /etc/profile.d/psql-utils.sh || true
psqlr --tuples-only --no-align -c \"\$QUERY\"
EOS
chmod +x /tmp/run-sql.sh"

  # Execute the query
  kubectl -n "${NS}" exec "${pod}" -- env QUERY="${query}" /tmp/run-sql.sh
  # Clean up
  kubectl -n "${NS}" exec "${pod}" -- rm -f /tmp/run-sql.sh >/dev/null 2>&1 || true
}

# Count *all* pods in the namespace (Succeeded/Failed still count toward quota while terminating)
count_pods() {
  kubectl -n "${NS}" get pods --no-headers 2>/dev/null | wc -l | tr -d '[:space:]'
}

cleanup_finished_jobs() {
  echo "[$(date +%FT%T)] Cleaning up completed Jobs + Pods in ${NS}…" | tee -a "${LOG_FILE}"

  # Delete Jobs that have succeeded at least once (and their Pods)
  kubectl -n "${NS}" get jobs -o json \
  | jq -r '.items[] | select((.status.succeeded // 0) > 0) | .metadata.name' \
  | xargs -r -n1 kubectl -n "${NS}" delete job

  # Belt-and-braces: remove any orphaned Pods from Jobs that already completed
  kubectl -n "${NS}" get pods --field-selector=status.phase==Succeeded -o name \
  | xargs -r kubectl -n "${NS}" delete
}

# Start one reindex job by node id (non-blocking) with graceful error handling
start_reindex_for_id() {
  local id="$1"
  local next=$(( id + 1 ))
  local job="reindexing-${id}-${next}"

  {
    if kubectl -n "${NS}" get job "${job}" >/dev/null 2>&1; then
      echo "[$(date +%FT%T)] Job for ${job} already exists — skipping."
      return 0
    fi
    echo "[$(date +%FT%T)] Starting reindex for id=${id} to=${next}"

    # run the task in background so we don't wait for it here
    task reindex_by_id ENV="${ENV_INPUT}" FROM="${id}" TO="${next}" SKIP_CM_DELETION="true" 2>&1 &
  } | tee -a "${LOG_FILE}"
}


# ---- 1) query DB and write IDs to a local file -----------------------------

echo "Querying database in ${NS} utils pod for missing doc node_ids…"
sql_in_utils "select node_id from moj_os_missing_docs ${WHERE_CLAUSE} order by 1 desc;" \
  | sed '/^[[:space:]]*$/d' > "${IDS_FILE}"

ID_COUNT="$(wc -l < "${IDS_FILE}" | tr -d '[:space:]')"
if [[ "${ID_COUNT}" -eq 0 ]]; then
  echo "No rows found in moj_os_missing_docs. Nothing to do." | tee -a "${LOG_FILE}"
  exit 0
fi

echo "Found ${ID_COUNT} node_id(s). Stored in: ${IDS_FILE}" | tee -a "${LOG_FILE}"
echo "Beginning throttled launch of reindex jobs (respecting ${MAX_PODS} pod cap)…" | tee -a "${LOG_FILE}"

# ---- 2) loop IDs and throttle by available pod slots -----------------------

# We’ll keep topping up: launch up to (MAX_PODS - current_pod_count) jobs,
# sleep briefly, and repeat until we’ve triggered all IDs.
launched=0

# Read IDs into an array (stable order: already DESC from SQL)
mapfile -t IDS < "${IDS_FILE}"

idx=0
total="${#IDS[@]}"
echo "Total IDs to process: ${total}" | tee -a "${LOG_FILE}"

while (( idx < total )); do
  # Current pod usage
  current="$(count_pods)"
  # Available headroom (never negative)
  if (( current >= MAX_PODS )); then
    # No room—wait a bit and check again
    cleanup_finished_jobs
    sleep 20
    continue
  fi

  capacity=$(( MAX_PODS - current ))
  # Be a bit conservative and don’t burst too quickly
  if (( capacity > 20 )); then capacity=20; fi

  # Launch up to 'capacity' jobs from the remaining list
  launched_this_round=0
  while (( launched_this_round < capacity && idx < total )); do
    echo "Processing index ${idx} of ${total} (launched so far: ${launched}), capacity: ${capacity}, total: ${total}, launched_this_round: ${launched_this_round}" | tee -a "${LOG_FILE}"
    id="${IDS[$idx]}"
    # Basic numeric sanity check
    if [[ "$id" =~ ^[0-9]+$ ]]; then
      start_reindex_for_id "$id"
      # Increment counters
      launched=$(( launched + 1 ))
      echo "Incremented launched count to ${launched}" | tee -a "${LOG_FILE}"
      launched_this_round=$(( launched_this_round + 1 ))
      echo "Incremented launched_this_round count to ${launched_this_round}" | tee -a "${LOG_FILE}"
      idx=$(( idx + 1 ))
      echo "Incremented idx to ${idx}" | tee -a "${LOG_FILE}"
    else
      echo "Skipping non-numeric id: $id" | tee -a "${LOG_FILE}"
      idx=$(( idx + 1 ))
    fi
  done

  echo "[`date +%FT%T`] Launched ${launched_this_round} job(s) this round (total launched: ${launched}/${total})." | tee -a "${LOG_FILE}"
  # Give the cluster a moment to create pods and reflect counts
  sleep 15
  cleanup_finished_jobs
done

echo
echo "All ${launched} reindex jobs have been triggered." | tee -a "${LOG_FILE}"
echo "Logs (per id) are under: ${LOG_DIR}" | tee -a "${LOG_FILE}"
echo "Tip: tail -f ${LOG_DIR}/id-*.log" | tee -a "${LOG_FILE}"