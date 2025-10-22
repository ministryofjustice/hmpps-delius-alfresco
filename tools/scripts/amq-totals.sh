#!/bin/bash
# amq-totals.sh
# Usage: ./amq-totals.sh <env> <queue_name> <stat>
# Example: ./amq-totals.sh dev acs-repo-transform-request size
# - <stat> can be size, enqueueCount, dequeueCount, consumerCount, etc.
# - If namespace is not provided, it defaults to the current kubectl context namespace.

env=$1

if [[ "$env" != "poc" && "$env" != "dev" && "$env" != "test" && "$env" != "stage" && "$env" != "preprod" && "$env" != "prod" ]]; then
    log_error "Invalid namespace. Allowed values: poc, dev, test, stage, preprod or prod."
    exit 1
fi

# Queue name to check
QUEUE_NAME=$2
STAT=$3

echo "Queue name: $QUEUE_NAME"

if [ "$env" == "poc" ]; then
  NS="hmpps-delius-alfrsco-${env}"
else
  NS="hmpps-delius-alfresco-${env}"
fi

# Brokers' URLs
#BROKERS=("https://localhost:8161" "https://localhost:8162" "https://localhost:8163")
#BROKERS=("https://localhost:8161")

# AmazonMQ console creds for queue polling
AMQ_URL="$(kubectl -n $NS get secret amazon-mq-broker-secret -o json | jq -r '.data.BROKER_CONSOLE_URL|@base64d')"
AMQ_USER="$(kubectl -n $NS get secret amazon-mq-broker-secret -o json | jq -r '.data|map_values(@base64d)|.BROKER_USERNAME')"
AMQ_PASS="$(kubectl -n $NS get secret amazon-mq-broker-secret -o json | jq -r '.data|map_values(@base64d)|.BROKER_PASSWORD')"

# if AMQ_URL is empty then try the multi-broker approach
if [ -z "$AMQ_URL" ]; then
    #echo "No AMQ URL found in secret, trying multi-broker approach" >&2
    BROKERS=()
    for i in 0 1 2; do
        url=$(kubectl -n $NS get secret amazon-mq-broker-secret -o json | jq -r ".data.BROKER_CONSOLE_URL_${i}|@base64d")
        if [ -n "$url" ] && [ "$url" != "null" ]; then
            BROKERS+=("$url")
        fi
    done
    if [ ${#BROKERS[@]} -eq 0 ]; then        
        echo "No AMQ URLs found in secret. Exiting." >&2
        exit 1
    fi
else
    BROKERS=("$AMQ_URL")
fi
#echo "AMQ URL: $AMQ_URL"
#echo "AMQ User: $AMQ_USER"
UTILS_POD=$(kubectl -n $NS get pods -l app=utils -o name 2>/dev/null | head -n1 | cut -d/ -f2 || true)

#echo "Using utils pod: $UTILS_POD"
if [ -z "$UTILS_POD" ]; then
    echo "No utils pod found in namespace. Exiting."
    exit 1
fi
# Function to get the queue size from a broker's XML data
get_queue_size() {
    local broker_url=$1
    # Fetch the XML data from the broker through the utils pod
    xml="$(kubectl -n $NS exec "$UTILS_POD" -- bash -lc "set -euo pipefail; [[ -f /etc/profile.d/utils-profile.sh ]] && . /etc/profile.d/utils-profile.sh || true; curl -s -k --user '${AMQ_USER}:${AMQ_PASS}' '${broker_url}/admin/xml/queues.jsp'")"
    #echo "Fetched XML data from broker: ${xml}" >&2

    # Parse the XML to extract the size of the specified queue using xmllint
    size="$(printf "%s" "$xml" | xmllint --xpath "string(//queue[@name='${QUEUE_NAME}']/stats/@${STAT})" - || echo 0)"

    # Return the queue size (default to 0 if null)
    echo "${size:-0}"
}

# Total queue size across all brokers
total_queue_size=0

# Loop over each broker and sum the queue sizes
for broker in "${BROKERS[@]}"; do
    queue_size=$(get_queue_size "$broker")
    echo "Count for stat ${STAT} on $broker: $queue_size"
    total_queue_size=$((total_queue_size + queue_size))
done

# Print the total queue size
echo "---------------------------------"
echo "Total messages in stat ${STAT} '$QUEUE_NAME': $total_queue_size"
