# HMPPS Delius Alfresco Utils Pod

## Overview

The Utils Pod provides an interactive container with essential utilities for troubleshooting and administrative tasks within the HMPPS Delius Alfresco ecosystem. It runs with restricted permissions following Kubernetes Pod Security Standards (PSS) and is designed for secure operational use.

## Features

- Pre-installed utilities: curl, jq, awscli
- Runs as non-root user (UID 999)
- Compatible with Kubernetes restricted PSS
- Interactive bash shell access
- Uses the Helm chart deployment model

## Deployment

### Prerequisites

- Kubernetes cluster with kubectl access
- Helm 3 installed
- Appropriate RBAC permissions to deploy pods in the target namespace

### Deploying the Utils Pod

```bash
# Navigate to the utils directory
cd tools/utils

# Deploy using Helm
helm upgrade --install utils . --set environment=<env>

# Where <env> is one of: dev, test, stage, preprod, prod
```

### Accessing the Pod

Once deployed you can access the pod using:

```bash
kubectl exec -it utils -- /bin/bash
```
