#!/bin/bash
cat > ../base/resources.yaml
kubectl kustomize
rm ../base/resources.yaml
