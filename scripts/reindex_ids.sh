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
MAX_PARALLEL=5

counter=0
pids=()

while IFS= read -r ID; do
  # skip blank lines
  [[ -z "$ID" ]] && continue
  
  echo "Reindexing ID: $ID" | tee -a "$LOG_FILE"
  
  java -jar -Dserver.port=0 /opt/app.jar \
    --alfresco.reindex.jobName=reindexByIds \
    --alfresco.reindex.pageSize="$PAGESIZE" \
    --alfresco.reindex.batchSize="$BATCHSIZE" \
    --alfresco.reindex.fromId="$ID" \
    --alfresco.reindex.toId="$((ID + 1))" \
    --alfresco.reindex.concurrentProcessors="$CONCURRENT" >> "$TOMCAT_LOG_FILE" 2>&1 &
  
  pids+=($!)
  counter=$((counter + 1))
  
  if [[ $counter -eq $MAX_PARALLEL ]]; then
    echo "Waiting for batch of $MAX_PARALLEL processes to complete..." | tee -a "$LOG_FILE"
    echo "Time: $(date)" | tee -a "$LOG_FILE"
    #echo "PIDs: ${pids[*]}" | tee -a "$LOG_FILE"
    
    # Poll until all PIDs are finished
    while true; do
      all_done=true
      for pid in "${pids[@]}"; do
        if ps -p "$pid" > /dev/null 2>&1; then
          all_done=false
          break
        fi
      done
      
      if [[ "$all_done" == "true" ]]; then
        echo "Batch complete." | tee -a "$LOG_FILE"
        rm -rf /tmp/tomcat.*  # clean up temp and log files between runs
        break
      fi
      
      sleep 2
    done
    
    pids=()
    counter=0
  fi
done < "$ID_FILE"

# Wait for any remaining processes
if [[ ${#pids[@]} -gt 0 ]]; then
  echo "Waiting for final batch of ${#pids[@]} processes to complete..." | tee -a "$LOG_FILE"
  echo "Time: $(date)" | tee -a "$LOG_FILE"
  #echo "PIDs: ${pids[*]}" | tee -a "$LOG_FILE
  
  # Poll until all PIDs are finished
  while true; do
    all_done=true
    for pid in "${pids[@]}"; do
      if ps -p "$pid" > /dev/null 2>&1; then
        all_done=false
        break
      fi
    done
    
    if [[ "$all_done" == "true" ]]; then
      echo "Final batch complete." | tee -a "$LOG_FILE"
      rm -rf /tmp/tomcat.*  # clean up temp and log files between runs
      break
    fi
    
    sleep 10
  done
fi

echo "✅ All IDs processed."