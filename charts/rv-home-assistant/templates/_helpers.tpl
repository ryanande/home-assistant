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
{{- printf "%s-mosquitto.%s.svc.cluster.local" .Release.Name .Release.Namespace -}}
{{- end -}}

{{/* LibreCoach image: vehicle_bridge and the Node-RED flows both come from it. */}}
{{- define "rvha.librecoachImage" -}}
{{- printf "ghcr.io/backroads4me/%s-librecoach:%s" .Values.librecoach.arch .Values.librecoach.version -}}
{{- end -}}

{{/* /data/options.json exactly as the add-on would receive it. */}}
{{- define "rvha.librecoachOptions" -}}
{{- $opts := deepCopy .Values.librecoach.options -}}
{{- $_ := set $opts "can_interface" .Values.canBus.interfaceName -}}
{{- $_ := set $opts "prevent_flow_updates" .Values.librecoach.nodeRed.preventFlowUpdates -}}
{{- toPrettyJson $opts -}}
{{- end -}}

{{/* SUPERVISOR_TOKEN from the HA token Secret; optional so pods start before it exists. */}}
{{- define "rvha.supervisorTokenEnv" -}}
- name: SUPERVISOR_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ .Values.librecoach.haTokenSecret }}
      key: token
      optional: true
{{- end -}}

{{/* nginx config for the Supervisor shim (see librecoach-shim.yaml). */}}
{{- define "rvha.supervisorShimConf" -}}
{{- $ha := printf "%s-home-assistant.%s.svc.cluster.local:%v" (include "rvha.fullname" .) .Release.Namespace .Values.homeAssistant.service.port -}}
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}

server {
  listen 8080;

  # No X-Forwarded-For: Home Assistant rejects it from untrusted proxies.
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection $connection_upgrade;
  proxy_read_timeout 1d;
  proxy_send_timeout 1d;

  location = /core/websocket {
    proxy_pass http://{{ $ha }}/api/websocket;
  }

  location /core/ {
    proxy_pass http://{{ $ha }}/;
  }

  location = /healthz {
    access_log off;
    return 200 "ok\n";
  }

  location / {
    return 404 "not emulated by the supervisor shim\n";
  }
}
{{- end -}}
