# Define the Helm chart name and release name
CHART_NAME := alfresco-content-services
VALUES := values.yaml
VALUES_ENV := values_$(ENV).yaml
DEBUG := false

# Retrieve secrets using kubectl
get_secrets:
	@SECRET=$$(awk '{print substr($$0, 19)}' <<< $$(kubectl get secrets alfresco-content-services-alfresco-repository-properties-secret -o jsonpath='{.data.alfresco-global\.properties}' | base64 -d)); \

	if [ -z "$${SECRET}" ]; then \
		SECRET=$$(openssl rand -base64 20); \
	fi; \

	BUCKET_NAME=$$(awk '{print substr($$0, 0)}' <<< $$(kubectl get secrets s3-bucket-output -o jsonpath='{.data.BUCKET_NAME}' | base64 -d)); \

	$(MAKE) helm_upgrade SECRET=$${SECRET} BUCKET_NAME=$${BUCKET_NAME}

# Helm upgrade/install command
helm_upgrade:
	@if [ "$(ENV)" = "poc" ]; then \
		NAMESPACE=hmpps-delius-alfrsco-$(ENV); \
	else \
		NAMESPACE=hmpps-delius-alfresco-$(ENV); \
	fi; \
	echo "Using namespace: $${NAMESPACE}"; \
	if [ "$(DEBUG)" = "true" ]; then \
		DEBUG_FLAG="--debug"; \
	else \
		DEBUG_FLAG=""; \
	fi; \
	helm upgrade --install $(CHART_NAME) ./$(CHART_NAME) --namespace $${NAMESPACE} \
	--values=./$(CHART_NAME)/$(VALUES) --values=./$(CHART_NAME)/$(VALUES_ENV) \
	--set s3connector.config.bucketName=$(BUCKET_NAME) \
    --set global.tracking.sharedsecret=$(SECRET) \
    --atomic $${DEBUG_FLAG}

# Default target
.PHONY: default
default: get_secrets

# Phony targets
.PHONY: get_secrets helm_upgrade
