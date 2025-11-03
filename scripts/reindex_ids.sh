#!/bin/bash
# Run Alfresco reindex-by-id for each ID in a file
# Usage: ./reindex_ids.sh /path/to/ids.txt
# Run this on the reindexing pod in the target namespace, e.g.
#   ns="hmpps-delius-alfresco-poc"
#   pod=$(kubectl -n "$ns" get pods -o name 2>/dev/null | grep reind | head -n1 | cut -d/ -f2 || true)
#   kubectl -n "$ns" cp reindex_ids.sh "$pod":/tmp/reindex_ids.sh
#   kubectl -n "$ns" cp ~/ids.txt "$pod":/tmp/ids.txt
#   kubectl -n "$ns" exec "$pod" -- bash -lc "nohup bash /tmp/reindex_ids.sh /tmp/ids.txt &"
# Notes:
#   - Requires the alfresco-elasticsearch-reindexing-app.jar to be present in the pod.
#   - The input file should contain one numeric ID per line.
#   - Adjust PAGESIZE, BATCHSIZE, and CONCURRENT as needed for performance tuning.
# -----------------------------------------------------------------------------

set -euo pipefail

ID_FILE="${1:-ids.txt}"

if [[ ! -f "$ID_FILE" ]]; then
  echo "❌ File '$ID_FILE' not found"
  exit 1
fi

# Optional: adjust these as needed
PAGESIZE=100
BATCHSIZE=100
CONCURRENT=2
LOG_FILE="/tmp/reindex_ids.log"
TOMCAT_LOG_FILE="/tmp/tomcat.log"

while IFS= read -r ID; do
  # skip blank lines
  [[ -z "$ID" ]] && continue
  rm -rf /tmp/tomcat.*  # clean up temp and log files between runs
  echo "Reindexing ID: $ID" | tee -a "$LOG_FILE"
  java -jar /opt/app.jar \
    --alfresco.reindex.jobName=reindexByIds \
    --alfresco.reindex.pageSize="$PAGESIZE" \
    --alfresco.reindex.batchSize="$BATCHSIZE" \
    --alfresco.reindex.fromId="$ID" \
    --alfresco.reindex.toId="$((ID + 1))" \
    --alfresco.reindex.concurrentProcessors="$CONCURRENT" | tee -a "$TOMCAT_LOG_FILE"
done < "$ID_FILE"

echo "✅ All IDs processed."