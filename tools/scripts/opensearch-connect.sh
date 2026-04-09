#!/usr/bin/env bash

# trap ctrl-c and call ctrl_c()
trap ctrl_c INT
# trap fail and call fail()
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
    case "$env" in
        poc|dev|test|stage|preprod|prod|training)
            ;;
        *)
            log_error "Invalid namespace. Allowed values: poc, dev, test, stage, preprod, prod or training."
            exit 1
            ;;
    esac

    if [ "$env" == "poc" ]; then
        namespace="hmpps-delius-alfrsco-${env}"
    else
        namespace="hmpps-delius-alfresco-${env}"
    fi
    log_info "Connecting to Opensearch in namespace $namespace"

    if [ -z "$2" ]; then
        PORT=8080
    else
        PORT=$2
    fi

    # get opensearch proxy pod name
    OPENSEARCH_PROXY_POD=$(kubectl get pods --namespace ${namespace} | grep 'opensearch-proxy-cloud-platform' | awk '{print $1}' | head -n 1)
    log_debug "\n****************************************************\n"
    log_debug "Connect to http://localhost:$PORT locally\n"
    log_debug "Press Ctrl+C to stop port forwarding \n"
    log_debug "****************************************************\n\n"
    # start the local port forwarding session
    kubectl port-forward $OPENSEARCH_PROXY_POD $PORT:8080 --namespace ${namespace}
}

fail() {
    log_error "\n\nPort forwarding failed"
    exit 1
}
ctrl_c() {
    log_error "\n\nStopping port forwarding"
    exit 0
}

if [ -z "$1" ]; then
    log_error "env not provided"
    log_error "Usage: opensearch-connect.sh <env>"
    exit 1
fi
main $1 $2
