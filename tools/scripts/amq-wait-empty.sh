#!/bin/bash

QUEUE_NAME=$1
STAT=$2
NAMESPACE=$3

if [ -z "$QUEUE_NAME" ] || [ -z "$STAT" ]; then
  echo "Usage: $0 <queue_name> <stat> [namespace]"
  exit 1
fi

while true; do
  total=$(./amq-totals.sh "$QUEUE_NAME" "$STAT" "$NAMESPACE" | \
          grep "Total messages in stat" | awk '{print $NF}')
  echo "Current total for $QUEUE_NAME ($STAT): $total"

  if [ "$total" -eq 0 ]; then
    echo "Queue is empty."
    osascript -e 'tell application "System Events" to display dialog "Queue ${QUEUE_NAME} is empty." with title "Alert Box"'
    exit 0
  fi

  echo "Sleeping 30s before next check..."
  sleep 30
done

