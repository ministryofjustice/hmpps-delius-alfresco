# Define the Helm chart name and release name
CHART_NAME := alfresco-content-services
VALUES := values.yaml
VALUES_ENV := values_$(ENV).yaml
DEBUG := false

# Helm upgrade/install command
helm_upgrade:
	@SECRET=$$(kubectl get secrets alfresco-content-services-alfresco-repository-properties-secret -o jsonpath='{.data.alfresco-global\.properties}' | base64 -d | awk '{print substr($$0, 19)}'); \
	if [ -z "$$SECRET" ]; then \
		SECRET=$$(openssl rand -base64 20); \
	fi; \

	$(eval BUCKET_NAME := $(shell kubectl get secrets s3-bucket-output -o jsonpath='{.data.BUCKET_NAME}' | base64 -d))

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
	echo "BUCKET_NAME: $(BUCKET_NAME)"; \
	helm upgrade --install $(CHART_NAME) ./$(CHART_NAME) --namespace $${NAMESPACE} \
	--values=./$(CHART_NAME)/$(VALUES) --values=./$(CHART_NAME)/$(VALUES_ENV) \
	--set s3connector.config.bucketName=$(BUCKET_NAME) \
    --set global.tracking.sharedsecret=$(SECRET) \
    --atomic $${DEBUG_FLAG} --wait --timeout=20m

# Default target
.PHONY: default
default: helm_upgrade

# Phony targets
.PHONY: helm_upgrade