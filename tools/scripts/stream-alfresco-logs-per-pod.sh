#!/bin/bash

# -----------------------------------------------------------------------------
# Script Name: stream-alfresco-logs-per-pod.sh
#
# Description:
#   Streams logs from all pods in a specified Kubernetes namespace related to
#   Alfresco, saving each pod's logs to a separate file in the local log directory.
#   The script supports environments: poc, dev, test, stage, preprod, and prod.
#
# Usage:
#   ./stream-alfresco-logs-per-pod.sh <poc|dev|test|stage|preprod|prod>
#
# Arguments:
#   <environment>   The target environment/namespace (poc, dev, test, stage, preprod, or prod).
#
# Features:
#   - Validates the provided environment argument.
#   - Determines the correct Kubernetes namespace based on the environment.
#   - Fetches all pod names in the namespace.
#   - Streams logs from each pod to a separate file under logs/.
#   - Handles cleanup of background log streaming processes on script exit or interruption.
#
# Notes:
#   - Requires kubectl to be configured with access to the target cluster.
#   - Log files are stored in the logs directory relative to the script.
# -----------------------------------------------------------------------------

if [ -z "${1:-}" ]; then
  echo "❌ No environment specified. Usage: $0 <poc|dev|test|stage|preprod|prod>"
  exit 1
fi

env=$1

# Restrict env values to only poc, dev, test, stage, preprod or prod
if [[ "$env" != "poc" && "$env" != "dev" && "$env" != "test" && "$env" != "stage" && "$env" != "preprod" && "$env" != "prod" ]]; then
    log_error "Invalid namespace. Allowed values: poc, dev, test, stage, preprod or prod."
    exit 1
fi

if [ "$env" == "poc" ]; then
    namespace="hmpps-delius-alfrsco-${env}"
else
    namespace="hmpps-delius-alfresco-${env}"
fi

NAMESPACE="${namespace}"
LOG_DIR="logs"
PIDS=()

mkdir -p "${LOG_DIR}"

# Function to clean up background processes on exit
cleanup() {
  echo -e "\nStopping all log streams..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null
  done
  wait
  echo "All background log streams stopped."
}

# Trap SIGINT (Ctrl+C) and SIGTERM
trap cleanup SIGINT SIGTERM

echo "Fetching list of pods in namespace ${NAMESPACE}..."
PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers -o custom-columns=":metadata.name")

for POD in $PODS; do
  LOG_FILE="${LOG_DIR}/${POD}.log"
  echo "Streaming logs for pod $POD to $LOG_FILE..."

  # Stream logs in background and store PID
  (kubectl logs -n "$NAMESPACE" -f "$POD" > "$LOG_FILE" 2>&1) &
  PIDS+=($!)
done

# Wait for all background processes to complete (which they won’t unless interrupted)
wait

