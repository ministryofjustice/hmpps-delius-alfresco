#!/bin/bash
while getopts d: flag
do
    case "${flag}" in
        d) debug=${OPTARG};;
    esac
done
if [ "$debug" == "true" ]; then
    set -x
    cat > ../base/resources.yaml
    kubectl kustomize
    kubectl kustomize > output.yaml
    echo "leaving helm template in resources.yaml"
    echo "leaving kustomized helm template in output.yaml"
else
    cat > ../base/resources.yaml
    kubectl kustomize
    rm ../base/resources.yaml
fi
