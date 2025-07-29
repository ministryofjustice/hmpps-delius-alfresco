#!/usr/bin/env bash
set -euo pipefail

# ─── Cleanup on exit ─────────────────────────────────────────────────────────────
# kill all child background jobs (the kubectl logs tails) on script exit
trap 'echo; echo "Stopping log streams…"; kill $(jobs -p) 2>/dev/null' EXIT


if [ -z "${1:-}" ]; then
  echo "❌ No environment specified. Usage: $0 <poc|dev|test|preprod>"
  exit 1
fi

# ——— CONFIG ——————————————————————————————————————
# Namespace to watch
env=$1

# Restrict env values to only poc, dev, test or preprod
if [[ "$env" != "poc" && "$env" != "dev" && "$env" != "test" && "$env" != "preprod" ]]; then
    log_error "Invalid namespace. Allowed values: poc, dev, test or preprod."
    exit 1
fi

if [ "$env" == "poc" ]; then
    namespace="hmpps-delius-alfrsco-${env}"
else
    namespace="hmpps-delius-alfresco-${env}"
fi

NAMESPACE="${namespace}"

# (Optional) Narrow to just the alfresco-repository pods:
LABEL_SELECTOR="app.kubernetes.io/name=alfresco-repository"
# If you want *all* pods in the namespace, set LABEL_SELECTOR=""
LABEL_SELECTOR=""

# ——————————————————————————————————————

# Build your log file name
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR="../../../alfresco-logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/alfresco-repo-logs-${TIMESTAMP}.log"

echo "👉 Streaming logs from namespace '$NAMESPACE' into $LOG_FILE"
echo "Press Ctrl+C to stop."

# Fetch pod list
if [[ -n "$LABEL_SELECTOR" ]]; then
  PODS=($(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].metadata.name}'))
else
  PODS=($(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}'))
fi

if [[ ${#PODS[@]} -eq 0 ]]; then
  echo "❌ No pods found in namespace $NAMESPACE with selector '$LABEL_SELECTOR'"
  exit 1
fi

# Stream logs for each pod
for POD in "${PODS[@]}"; do
  echo "  • Attaching to logs for pod $POD"
  kubectl logs -n "$NAMESPACE" "$POD" --follow --all-containers \
    >> "$LOG_FILE" 2>&1 &
done

# Wait on all background jobs (until Ctrl+C)
wait

