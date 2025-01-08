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
    cp ../base/resources.yaml helm_rendered_spec.yaml
    kubectl kustomize
    kubectl kustomize > kustomized_helm_rendered_spec.yaml
else
    cat > ../base/resources.yaml
    kubectl kustomize
    rm ../base/resources.yaml
fi
