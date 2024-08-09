# Define the Helm chart name and release name
CHART_NAME := delius
DEBUG := false
ATOMIC := true

# Helm upgrade/install command
helm_upgrade:
	$(eval BUCKET_NAME := $(shell kubectl get secrets s3-bucket-output -o jsonpath='{.data.BUCKET_NAME}' | base64 -d))
	@if [ "$(ENV)" = "poc" ]; then \
		NAMESPACE=hmpps-delius-alfrsco-$(ENV); \
	else \
		NAMESPACE=hmpps-delius-alfresco-$(ENV); \
	fi; \
	echo "Using namespace: $${NAMESPACE}"; \
	if [ "$(DEBUG)" = "true" ]; then \
		DEBUG_FLAG="--debug"; \
		HELM_POST_RENDERER_ARGS="-d true"; \
	else \
		DEBUG_FLAG=""; \
		HELM_POST_RENDERER_ARGS="-d false"; \
	fi; \
	if [ "$(ATOMIC)" = "true" ]; then \
		ATOMIC_FLAG="--atomic"; \
	else \
		ATOMIC_FLAG=""; \
	fi; \
	echo "BUCKET_NAME: $(BUCKET_NAME)"; \
	cd ./kustomize/$${ENV}; \
    extracted=$$(yq 'join(",")' ./allowlist.yaml); \
    echo "Whitelist: $$extracted"; \
    export extracted=$$extracted; \
    yq '.metadata.annotations."nginx.ingress.kubernetes.io/whitelist-source-range" = strenv(extracted)' -i ./patch-ingress-repository.yaml; \
    yq '.metadata.annotations."nginx.ingress.kubernetes.io/whitelist-source-range" = strenv(extracted)' -i ./patch-ingress-share.yaml; \
    helm repo add alfresco https://kubernetes-charts.alfresco.com/stable --force-update; \
	helm upgrade --install $(CHART_NAME) alfresco/alfresco-content-services --version 6.0.2 --namespace $${NAMESPACE} \
	--values=../base/values.yaml --values=./values.yaml \
	--set s3connector.config.bucketName=$(BUCKET_NAME) \
    --wait --timeout=20m \
	--post-renderer ../kustomizer.sh --post-renderer-args "$${HELM_POST_RENDERER_ARGS}"; \
	yq '.metadata.annotations."nginx.ingress.kubernetes.io/whitelist-source-range" = "placeholder"' -i ./patch-ingress-repository.yaml; \
	yq '.metadata.annotations."nginx.ingress.kubernetes.io/whitelist-source-range" = "placeholder"' -i ./patch-ingress-share.yaml

# Default target
.PHONY: default
default: helm_upgrade

# Phony targets
.PHONY: helm_upgrade
