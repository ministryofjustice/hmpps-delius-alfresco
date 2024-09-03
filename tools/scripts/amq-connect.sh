#!/usr/bin/env bash

# trap ctrl-c and call ctrl_c()
trap ctrl_c INT
# trap fail and call fail()
trap fail ERR

main() {        
    env=$1
    if [ "$env" == "poc" ]; then
        namespace="hmpps-delius-alfrsco-${env}"
    else 
        namespace="hmpps-delius-alfresco-${env}"
    fi
    echo "Connecting to AMQ Console in namespace $namespace"
       
    # get amq connection url
    URL=$(kubectl get secrets amazon-mq-broker-secret --namespace ${namespace} -o json | jq -r ".data.BROKER_CONSOLE_URL | @base64d")
    # extract host and port
    HOST=$(echo $URL | cut -d '/' -f 3 | cut -d ':' -f 1)
    # extract protocol
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
    # start port forwarding
    kubectl run port-forward-pod-${RANDOM_HEX} --image=ghcr.io/ministryofjustice/hmpps-delius-alfresco-port-forward-pod:latest --port ${LOCAL_PORT} --env="REMOTE_HOST=$HOST" --env="LOCAL_PORT=$LOCAL_PORT" --env="REMOTE_PORT=$REMOTE_PORT" --namespace ${namespace};
    # wait for pod to start
    kubectl wait --for=condition=ready pod/port-forward-pod-${RANDOM_HEX} --timeout=30s --namespace ${namespace}
    printf "\nPort forwarding started, connecting to $HOST:$REMOTE_PORT \n"
    printf "\n****************************************************\n"
    printf "Connect to ${PROTOCOL}://localhost:$LOCAL_PORT locally\n"
    printf "Press Ctrl+C to stop port forwarding \n"
    printf "****************************************************\n\n"
    # start the local port forwarding session
    kubectl port-forward --namespace ${namespace} port-forward-pod-${RANDOM_HEX} $LOCAL_PORT:$LOCAL_PORT;
}

fail() {
    printf "\n\nPort forwarding failed"
    kubectl delete pod port-forward-pod-${RANDOM_HEX} --force --grace-period=0  --namespace ${namespace}
    exit 1
}
ctrl_c() {
    printf "\n\nStopping port forwarding"
    kubectl delete pod port-forward-pod-${RANDOM_HEX} --force --grace-period=0  --namespace ${namespace}
    exit 0
}

if [ -z "$1" ]; then
    echo "env not provided"
    echo "Usage: amq-connect.sh <env>"
    exit 1
fi
main $1 $2
