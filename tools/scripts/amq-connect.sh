#!/usr/bin/env bash

# trap ctrl-c and call ctrl_c()
trap ctrl_c INT
# trap fail and call fail()
trap fail ERR

main() {        
    env=$1
    
    # Restrict env values to only stage, preprod or prod
    if [[ "$env" != "stage" && "$env" != "preprod" && "$env" != "prod" ]]; then
        echo "Invalid namespace. Allowed values: stage, preprod, or prod."
        exit 1
    fi
 
    namespace="hmpps-delius-alfresco-${env}"
    echo "Connecting to AMQ Console in namespace $namespace"
       
    # get amq connection url
    URL0=$(kubectl get secrets amazon-mq-broker-secret --namespace ${namespace} -o json | jq -r ".data.BROKER_CONSOLE_URL_0 | @base64d")

    URL1=$(kubectl get secrets amazon-mq-broker-secret --namespace ${namespace} -o json | jq -r ".data.BROKER_CONSOLE_URL_1 | @base64d")

    URL2=$(kubectl get secrets amazon-mq-broker-secret --namespace ${namespace} -o json | jq -r ".data.BROKER_CONSOLE_URL_2 | @base64d")

    LOCAL_PORT_0=8161
    LOCAL_PORT_1=8162
    LOCAL_PORT_2=8163

    # extract host and port
    HOST_0=$(echo $URL0 | cut -d '/' -f 3 | cut -d ':' -f 1)
    # extract protocol
    PROTOCOL_0=$(echo $URL0 | awk -F'://' '{print $1}')
    # extract remote port
    REMOTE_PORT_0=$(echo $URL0 | cut -d '/' -f 3 | cut -d ':' -f 2)

    HOST_1=$(echo $URL1 | cut -d '/' -f 3 | cut -d ':' -f 1)
    PROTOCOL_1=$(echo $URL1 | awk -F'://' '{print $1}')
    REMOTE_PORT_1=$(echo $URL1 | cut -d '/' -f 3 | cut -d ':' -f 2)

    HOST_2=$(echo $URL2 | cut -d '/' -f 3 | cut -d ':' -f 1)
    PROTOCOL_2=$(echo $URL2 | awk -F'://' '{print $1}')
    REMOTE_PORT_2=$(echo $URL2 | cut -d '/' -f 3 | cut -d ':' -f 2)

    # generate random hex string
    RANDOM_HEX=$(openssl rand -hex 4)

    # start port forwarding
    POD_NAME_0="port-forward-pod-${RANDOM_HEX}-0"
    POD_NAME_1="port-forward-pod-${RANDOM_HEX}-1"
    POD_NAME_2="port-forward-pod-${RANDOM_HEX}-2"

    kubectl run $POD_NAME_0 --image=ghcr.io/ministryofjustice/hmpps-delius-alfresco-port-forward-pod:latest --port ${LOCAL_PORT_0} --env="REMOTE_HOST=$HOST_0" --env="LOCAL_PORT=$LOCAL_PORT_0" --env="REMOTE_PORT=$REMOTE_PORT_0" --namespace ${namespace};
    kubectl run $POD_NAME_1 --image=ghcr.io/ministryofjustice/hmpps-delius-alfresco-port-forward-pod:latest --port ${LOCAL_PORT_1} --env="REMOTE_HOST=$HOST_1" --env="LOCAL_PORT=$LOCAL_PORT_1" --env="REMOTE_PORT=$REMOTE_PORT_1" --namespace ${namespace};
    kubectl run $POD_NAME_2 --image=ghcr.io/ministryofjustice/hmpps-delius-alfresco-port-forward-pod:latest --port ${LOCAL_PORT_2} --env="REMOTE_HOST=$HOST_2" --env="LOCAL_PORT=$LOCAL_PORT_2" --env="REMOTE_PORT=$REMOTE_PORT_2" --namespace ${namespace};
    
    # wait for pod to start
    kubectl wait --for=condition=ready $POD_NAME_0 --timeout=120s --namespace ${namespace}
    kubectl wait --for=condition=ready $POD_NAME_1 --timeout=120s --namespace ${namespace}
    kubectl wait --for=condition=ready $POD_NAME_2 --timeout=120s --namespace ${namespace}
    sleep 30
    for i in {0..2}; do
        HOST_VAR="HOST_${i}"
        REMOTE_PORT_VAR="REMOTE_PORT_${i}"
        PROTOCOL_VAR="PROTOCOL_${i}"
        LOCAL_PORT_VAR="LOCAL_PORT_${i}"

        HOST="${!HOST_VAR}"
        REMOTE_PORT="${!REMOTE_PORT_VAR}"
        PROTOCOL="${!PROTOCOL_VAR}"
        LOCAL_PORT="${!LOCAL_PORT_VAR}"

        printf "\nPort forwarding started, connecting to $HOST:$REMOTE_PORT \n"
        printf "\n****************************************************\n"
        printf "Connect to ${PROTOCOL}://localhost:$LOCAL_PORT locally\n"
        printf "Press Ctrl+C to stop port forwarding \n"
        printf "****************************************************\n\n"
    done
    
    # start the local port forwarding session
    kubectl port-forward --namespace ${namespace} $POD_NAME_0 $LOCAL_PORT_0:$LOCAL_PORT_0 &
    PORT_FORWARD_PID_0=$!
    kubectl port-forward --namespace ${namespace} $POD_NAME_1 $LOCAL_PORT_1:$LOCAL_PORT_1 &
    PORT_FORWARD_PID_1=$!
    kubectl port-forward --namespace ${namespace} $POD_NAME_2 $LOCAL_PORT_2:$LOCAL_PORT_2 &
    PORT_FORWARD_PID_2=$!
    wait

    # Keep the script running, listening for ctrl+c
    while true; do
        sleep 1
    done
}

fail() {
    printf "\n\nPort forwarding failed"
    cleanup
    exit 1
}
ctrl_c() {
    printf "\n\nStopping port forwarding"
    cleanup
    exit 0
}

cleanup() {
    echo "Cleaning up..."
    kill $PORT_FORWARD_PID_0 2>/dev/null || true
    kill $PORT_FORWARD_PID_1 2>/dev/null || true
    kill $PORT_FORWARD_PID_2 2>/dev/null || true
    kubectl delete pod $POD_NAME_0 --force --grace-period=0 --namespace=${namespace} 2>/dev/null || true
    kubectl delete pod $POD_NAME_1 --force --grace-period=0 --namespace=${namespace} 2>/dev/null || true
    kubectl delete pod $POD_NAME_2 --force --grace-period=0 --namespace=${namespace} 2>/dev/null || true
    echo "Cleanup complete."
}

if [ -z "$1" ]; then
    echo "env not provided"
    echo "Usage: amq-connect.sh <env>"
    exit 1
fi
main "$1" "$2"
