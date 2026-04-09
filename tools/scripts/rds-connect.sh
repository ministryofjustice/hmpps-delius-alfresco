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
    log_info "Connecting to RDS in namespace $namespace"
    
    # get RDS connection url
    URL=$(kubectl get secrets rds-instance-output --namespace ${namespace} -o json | jq -r ".data.RDS_JDBC_URL | @base64d")
    # extract host and port
    HOST=$(echo $URL | cut -d '/' -f 3 | cut -d ':' -f 1)
    # extract database name
    DATABASE_NAME=$(echo "$URL" | awk -F'/' '{print $NF}')
    # extract protocol/jdbc
    PROTOCOL=$(echo $URL | awk -F'://' '{print $1}')
    # extract remote port
    REMOTE_PORT=$(echo $URL | cut -d '/' -f 3 | cut -d ':' -f 2)
    # if custom local port not provided, use remote port
    if [ -z "$2" ]; then
        LOCAL_PORT=$REMOTE_PORT
    else
        LOCAL_PORT=$2
    fi
    # generate random hex string
    RANDOM_HEX=$(openssl rand -hex 4)
    # check for existing port-forward pod and use that if found
    #existing_pod=$(kubectl get pods --namespace ${namespace} -o json | jq -r ".items[] | select(.metadata.name | startswith(\"port-forward-pod-\")) | .metadata.name" | head -n1)
    existing_pod=    
    if [ -n "$existing_pod" ]; then
        log_info "Found existing port-forwarding pod: $existing_pod"
        POD_NAME=$existing_pod
    else
        POD_NAME="port-forward-pod-${RANDOM_HEX}"
        # start port forwarding
        kubectl run $POD_NAME --image=ghcr.io/ministryofjustice/hmpps-delius-alfresco-port-forward-pod:latest --port ${LOCAL_PORT} --env="REMOTE_HOST=$HOST" --env="LOCAL_PORT=$LOCAL_PORT" --env="REMOTE_PORT=$REMOTE_PORT" --namespace ${namespace}; 
        # wait for pod to start
        kubectl wait --for=condition=ready pod/port-forward-pod-${RANDOM_HEX} --timeout=30s --namespace ${namespace}
    fi
    log_debug "\n****************************************************\n"   
    log_debug "Connect to ${PROTOCOL}://localhost:$LOCAL_PORT/$DATABASE_NAME locally\n"
    log_debug "Press Ctrl+C to stop port forwarding \n"
    log_debug "****************************************************\n\n"
    # start the local port forwarding session
    kubectl port-forward --namespace ${namespace} $POD_NAME $LOCAL_PORT:$LOCAL_PORT;
    if [ $? -ne 0 ]; then
        fail
    fi
}

fail() {
    log_error "\n\nPort forwarding failed"
    exit 1
}

ctrl_c() {
    log_error "\n\nStopping port forwarding"
    if [ -n "$POD_NAME" ]; then
        log_error "\nDeleting port forwarding pod $POD_NAME"
        kubectl delete pod $POD_NAME --force --grace-period=0  --namespace ${namespace}
    fi
    exit 0
}

if [ -z "$1" ]; then
    log_error "env not provided"
    log_error "Usage: rds-connect.sh <env>"
    exit 1
fi
main $1 $2
