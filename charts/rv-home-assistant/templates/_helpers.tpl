{{/* Chart name, truncated to the 63-char DNS label limit. */}}
{{- define "rvha.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified base name: <release> (or <release>-<chart> if they differ). */}}
{{- define "rvha.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains (include "rvha.name" .) .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "rvha.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Common labels. Pass a dict: (dict "ctx" $ "component" "x"). */}}
{{- define "rvha.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .ctx.Chart.Name .ctx.Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "rvha.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
app.kubernetes.io/part-of: rv-home-assistant
{{- end -}}

{{/* Selector labels - must stay immutable across upgrades. */}}
{{- define "rvha.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rvha.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* In-cluster MQTT host; must match the mosquitto subchart's Service name. */}}
{{- define "rvha.mqttHost" -}}
{{- if .Values.canBridge.mqtt.host -}}
{{- .Values.canBridge.mqtt.host -}}
{{- else -}}
{{- printf "%s-mosquitto.%s.svc.cluster.local" .Release.Name .Release.Namespace -}}
{{- end -}}
{{- end -}}
