# Define the Helm chart name and release name
CHART_NAME := alfresco-content-services
DEBUG := false
ATOMIC := true

# Environment variable (ensure this is set or default it)
ENV ?= poc

# Helm upgrade/install command
helm_upgrade:
	@$(eval BUCKET_NAME := $(shell kubectl get secrets s3-bucket-output -o jsonpath='{.data.BUCKET_NAME}' | base64 -d))
	if [ "$(ENV)" == "poc" ]; then \
		NAMESPACE=hmpps-delius-alfrsco-$(ENV); \
	else \
		NAMESPACE=hmpps-delius-alfresco-$(ENV); \
	fi; \
	echo "Using namespace: $${NAMESPACE}"; \
	DEBUG_FLAG=""; \
	HELM_POST_RENDERER_ARGS="-d false"; \
	if [ "$(DEBUG)" = "true" ]; then \
		DEBUG_FLAG="--debug"; \
		HELM_POST_RENDERER_ARGS="-d true"; \
	fi; \
	ATOMIC_FLAG=""; \
	if [ "$(ATOMIC)" = "true" ]; then \
		ATOMIC_FLAG="--atomic"; \
	fi; \
	echo "BUCKET_NAME: $(BUCKET_NAME)"; \
	cd ./kustomize/$${ENV}; \
	OPENSEARCH_PREFIX=$$(kubectl get svc --namespace $${NAMESPACE} | grep 'opensearch-proxy-service-cloud-platform' | awk '{print $$1}'); \
	OPENSEARCH_HOST=$${OPENSEARCH_PREFIX}.$${NAMESPACE}.svc.cluster.local; \
	echo "OpenSearch Host: $${OPENSEARCH_HOST}"; \
	RDS_JDBC_URL=$$(kubectl get secrets rds-instance-output --namespace $${NAMESPACE} -o json | jq -r ".data | map_values(@base64d) | .RDS_JDBC_URL"); \
    extracted=$$(yq 'join(",")' ./allowlist.yaml); \
	export extracted; \
    echo "Whitelist: $${extracted}"; \
    yq '.metadata.annotations."nginx.ingress.kubernetes.io/whitelist-source-range" = strenv(extracted)' -i ./patch-ingress-repository.yaml; \
    yq '.metadata.annotations."nginx.ingress.kubernetes.io/whitelist-source-range" = strenv(extracted)' -i ./patch-ingress-share.yaml; \
    helm repo add alfresco https://kubernetes-charts.alfresco.com/stable --force-update; \
	helm upgrade --install $(CHART_NAME) alfresco/alfresco-content-services --version 6.0.2 --namespace $${NAMESPACE} \
	--values=../base/values.yaml --values=./values.yaml \
	--set s3connector.config.bucketName=$(BUCKET_NAME) \
	--set database.url=$${RDS_JDBC_URL} \
    --set global.elasticsearch.host=$${OPENSEARCH_HOST} \
	--set alfresco-search-enterprise.searchIndex.host=$${OPENSEARCH_HOST} \
    --wait --timeout=20m \
	--post-renderer ../kustomizer.sh --post-renderer-args "$${HELM_POST_RENDERER_ARGS}" \
	$${DEBUG_FLAG} $${ATOMIC_FLAG}; \
	yq '.metadata.annotations."nginx.ingress.kubernetes.io/whitelist-source-range" = "placeholder"' -i ./patch-ingress-repository.yaml; \
	yq '.metadata.annotations."nginx.ingress.kubernetes.io/whitelist-source-range" = "placeholder"' -i ./patch-ingress-share.yaml

# Default target
.PHONY: default
default: helm_upgrade

# Phony targets
.PHONY: helm_upgrade
