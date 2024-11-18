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
    echo "Connecting to Opensearch in namespace $namespace"

    if [ -z "$2" ]; then
        PORT=8080
    else
        PORT=$2
    fi

    # get opensearch proxy pod name
    OPENSEARCH_PROXY_POD=$(kubectl get pods --namespace ${namespace} | grep 'opensearch-proxy-cloud-platform' | awk '{print $1}' | head -n 1)
    printf "\n****************************************************\n"
    printf "Connect to http://localhost:$PORT locally\n"
    printf "Press Ctrl+C to stop port forwarding \n"
    printf "****************************************************\n\n"
    # start the local port forwarding session
    kubectl port-forward $OPENSEARCH_PROXY_POD $PORT:8080 --namespace ${namespace}
}

fail() {
    printf "\n\nPort forwarding failed"
    exit 1
}
ctrl_c() {
    printf "\n\nStopping port forwarding"
    exit 0
}

if [ -z "$1" ]; then
    echo "env not provided"
    echo "Usage: opensearch-connect.sh <env>"
    exit 1
fi
main $1 $2
