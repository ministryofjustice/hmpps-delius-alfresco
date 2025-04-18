#!/usr/bin/env bash

# trap (ctrl+c) and call ctrl_c()
trap ctrl_c SIGINT

# trap failures and call fail()
trap fail ERR

# color variables
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

log_info() {
    echo -e "${GREEN}$1${RESET}"
}

log_error() {
    echo -e "${RED}$1${RESET}"
}

log_debug() {
    echo -e "${YELLOW}$1${RESET}"
}

main() {
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
    
    log_info "Connecting to AMQ Console in namespace $namespace"

    # get amq connection url
    URL=$(kubectl get secrets amazon-mq-broker-secret --namespace ${namespace} -o json | jq -r ".data.BROKER_CONSOLE_URL | @base64d")
    LOCAL_PORT=8161

    # extract host and port
    HOST=$(echo $URL | cut -d '/' -f 3 | cut -d ':' -f 1)
    # extract protocol
    PROTOCOL=$(echo $URL | awk -F'://' '{print $1}')
    # extract remote port
    REMOTE_PORT=$(echo $URL | cut -d '/' -f 3 | cut -d ':' -f 2)

    # generate random hex string
    RANDOM_HEX=$(openssl rand -hex 4)

    # start port forwarding
    POD_NAME="port-forward-pod-${RANDOM_HEX}"
    kubectl run $POD_NAME \
        --image=ghcr.io/ministryofjustice/hmpps-delius-alfresco-port-forward-pod:latest \
        --port ${LOCAL_PORT} \
        --env="REMOTE_HOST=$HOST" \
        --env="LOCAL_PORT=$LOCAL_PORT" \
        --env="REMOTE_PORT=$REMOTE_PORT" \
        --namespace ${namespace}

    # wait for pod to start
    kubectl wait --for=condition=ready pod/${POD_NAME} --timeout=60s --namespace ${namespace}

    log_debug "\nPort forwarding started, connecting to $HOST:$REMOTE_PORT \n"
    log_debug "\n****************************************************\n"
    log_debug "Connect to ${PROTOCOL}://localhost:$LOCAL_PORT locally\n"
    log_debug "Press Ctrl+C to stop port forwarding \n"
    log_debug "****************************************************\n\n"
    
    # start the local port forwarding session
    kubectl port-forward --namespace ${namespace} ${POD_NAME} $LOCAL_PORT:$LOCAL_PORT &
    PORT_FORWARD_PID=$!

    # Keep the script running, listening for ctrl+c
    while true; do
        sleep 1
    done
}

fail() {
    log_error "\n\nPort forwarding failed"
    cleanup
    exit 1
}
ctrl_c() {
    log_error "\n\nStopping port forwarding"
    cleanup
    exit 0
}

cleanup() {
    log_info "Cleaning up..."
    kill $PORT_FORWARD_PID 2>/dev/null || true
    kubectl delete pod $POD_NAME --force --grace-period=0 --namespace=${namespace} 2>/dev/null || true
    log_info "Cleanup complete."
}


if [ -z "$1" ]; then
    log_info "env not provided"
    log_info "Usage: amq-connect-single.sh <env>"
    exit 1
fi
main "$1" "$2"