# Define the Helm chart name and release name
CHART_NAME := alfresco-content-services
VALUES := values.yaml
VALUES_ENV := values_$(ENV).yaml
DEBUG := false
ATOMIC := true

# Helm upgrade/install command
helm_upgrade:
	$(eval BUCKET_NAME := $(shell kubectl get secrets s3-bucket-output -o jsonpath='{.data.BUCKET_NAME}' | base64 -d))
	
	@SECRET=$$(kubectl get secrets alfresco-content-services-alfresco-repository-properties-secret -o jsonpath='{.data.alfresco-global\.properties}' | base64 -d | awk '{print substr($$0, 19)}'); \
	if [ -z "$$SECRET" ]; then \
		SECRET=$$(openssl rand -base64 20); \
	fi; \
	if [ "$(ENV)" = "poc" ]; then \
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
	if [ "$(ATOMIC)" = "true" ]; then \
		ATOMIC_FLAG="--atomic"; \
	else \
		ATOMIC_FLAG=""; \
	fi; \
	echo "BUCKET_NAME: $(BUCKET_NAME)"; \
	helm upgrade --install $(CHART_NAME) ./$(CHART_NAME) --namespace $${NAMESPACE} \
	--values=./$(CHART_NAME)/$(VALUES) --values=./$(CHART_NAME)/$(VALUES_ENV) \
	--set s3connector.config.bucketName=$(BUCKET_NAME) \
    --set global.tracking.sharedsecret=$${SECRET} $${ATOMIC_FLAG} $${DEBUG_FLAG} --wait --timeout=20m

kustomize_apply:
	@if [ "$(ENV)" = "poc" ]; then \
		NAMESPACE=hmpps-delius-alfrsco-$(ENV); \
	else \
		NAMESPACE=hmpps-delius-alfresco-$(ENV); \
	fi; \
	echo "Using namespace: $${NAMESPACE}"; \
	extracted=$$(yq 'join(",")' ./kustomize/overlays/$(ENV)/allowlist.yaml); \
	yq '.metadata.annotations."nginx.ingress.kubernetes.io/whitelist-source-range" = env(extracted)' -i ./kustomize/overlays/$(ENV)/ingress-repository.yaml; \
	yq '.metadata.annotations."nginx.ingress.kubernetes.io/whitelist-source-range" = env(extracted)' -i ./kustomize/overlays/$(ENV)/ingress-share.yaml; \
	kustomize build --enable-helm --load-restrictor=LoadRestrictionsNone ./kustomize/overlays/$(ENV) | kubectl apply -f - --namespace $${NAMESPACE}; \
	yq '.metadata.annotations."nginx.ingress.kubernetes.io/whitelist-source-range" = "placeholder"' -i ./kustomize/overlays/$(ENV)/ingress-repository.yaml; \
	yq '.metadata.annotations."nginx.ingress.kubernetes.io/whitelist-source-range" = "placeholder"' -i ./kustomize/overlays/$(ENV)/ingress-share.yaml

kustomize_delete:
	@if [ "$(ENV)" = "poc" ]; then \
		NAMESPACE=hmpps-delius-alfrsco-$(ENV); \
	else \
		NAMESPACE=hmpps-delius-alfresco-$(ENV); \
	fi; \
	kubectl delete all -l deployment=hmpps-delius-alfresco --namespace $${NAMESPACE}

# Default target
.PHONY: default
default: helm_upgrade

# Phony targets
.PHONY: helm_upgrade

.PHONY: kustomize_apply

.PHONY: kustomize_delete
