#!/bin/bash
while getopts d: flag
do
    case "${flag}" in
        d) debug=${OPTARG};;
    esac
done
debug=$(echo $debug | xargs)
if [ "$debug" == "true" ]; then
    set -x
    cat > ../base/resources.yaml
    kubectl kustomize
    kubectl kustomize > output.yaml
else
    cat > ../base/resources.yaml
    kubectl kustomize
    rm ../base/resources.yaml
fi
