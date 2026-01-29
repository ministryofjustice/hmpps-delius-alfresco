#!/bin/bash
set -euo pipefail

NAMESPACE="$1"
INGRESS_NAME="$2"
MESSAGE="$3"

cat > tmp-maintenance-banner.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $INGRESS_NAME
  namespace: $NAMESPACE
  annotations:
    alb.ingress.kubernetes.io/actions.maintenance: >
      {"Type":"fixed-response","FixedResponseConfig":{"ContentType":"text/html","StatusCode":"503","MessageBody":"$MESSAGE"}} 
spec:
  rules:
    - http:
        paths:
          - path: /*
            pathType: ImplementationSpecific
            backend:
              service:
                name: maintenance
                port:
                  name: use-annotation
EOF
