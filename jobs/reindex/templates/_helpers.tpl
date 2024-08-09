{{- define "content-services.shortname" -}}
{{- $name := (.Values.NameOverride | default "alfresco-cs") -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "spring.activemq.env" -}}
- name: SPRING_ACTIVEMQ_BROKERURL
  value: $(BROKER_URL)
- name: SPRING_ACTIVEMQ_USER
  value: $(BROKER_USERNAME)
- name: SPRING_ACTIVEMQ_PASSWORD
  value: $(BROKER_PASSWORD)
{{- end -}}

{{- define "alfresco-search-enterprise.searchIndexExistingSecretName" -}}
{{ .Values.global.elasticsearch.existingSecretName }}
{{- end -}}

{{- define "alfresco-search-enterprise.config.spring" -}}
{{- if and (not .Values.global.elasticsearch.host) (not .Values.searchIndex.host) }}
  {{ fail "Please provide external elasticsearch connection details as values under .global.elasticsearch or .searchIndex or enable the embedded elasticsearch via .elasticsearch.enabled" }}
{{- end }}
  SPRING_ELASTICSEARCH_REST_URIS: "{{ .Values.global.elasticsearch.protocol }}://{{ .Values.global.elasticsearch.host }}:{{ .Values.global.elasticsearch.port }}"
{{- end -}}
