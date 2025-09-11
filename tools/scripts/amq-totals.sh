#!/bin/bash

if [ "$3" == "" ]; then
    NAMESPACE=""
else
    NAMESPACE="--namespace $3"
fi

# Queue name to check
QUEUE_NAME=$1

STAT=$2

echo "Queue name: $QUEUE_NAME"

# Brokers' URLs
#BROKERS=("https://localhost:8161" "https://localhost:8162" "https://localhost:8163")
BROKERS=("https://localhost:8161")

# ActiveMQ credentials (username:password)
USER=$(kubectl get secrets ${NAMESPACE} amazon-mq-broker-secret -o json | jq -r ".data | map_values(@base64d) | .BROKER_USERNAME")
PASSWORD=$(kubectl get secrets ${NAMESPACE} amazon-mq-broker-secret -o json | jq -r ".data | map_values(@base64d) | .BROKER_PASSWORD")

# Function to get the queue size from a broker's XML data
get_queue_size() {
    local broker_url=$1

    # echo "Getting queue size from $broker_url for queue $QUEUE_NAME"
    
    # URL to get queue information in XML format
    xml_url="${broker_url}/admin/xml/queues.jsp"

    # Fetch the XML data from the broker
    xml_data=$(curl -s -k --user "$USER:$PASSWORD" "$xml_url")

    # Parse the XML to extract the size of the specified queue using xmllint
    queue_size=$(echo "$xml_data" | xmllint --xpath "string(//queue[@name='$QUEUE_NAME']/stats/@${STAT})" -)
    # echo "Queue size: $queue_size"

    # Return the queue size (default to 0 if null)
    echo "${queue_size:-0}"
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
