{{/* Service/Deployment name: <release>-mosquitto. The parent chart's
     rvha.mqttHost helper depends on this exact format. */}}
{{- define "mosquitto.fullname" -}}
{{- printf "%s-mosquitto" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mosquitto.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/name: mosquitto
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: mqtt-broker
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: rv-home-assistant
{{- end -}}

{{- define "mosquitto.selectorLabels" -}}
app.kubernetes.io/name: mosquitto
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
