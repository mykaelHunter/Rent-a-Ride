{{/*
Chart name.
*/}}
{{- define "rent-a-ride.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully-qualified app name.
*/}}
{{- define "rent-a-ride.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart name and version, used in the chart label.
*/}}
{{- define "rent-a-ride.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Namespace this chart's resources are installed into. This mirrors the
original k8s/*.yaml manifests, which all hardcoded metadata.namespace:
rent-a-ride, regardless of the Helm release namespace passed on the CLI.
*/}}
{{- define "rent-a-ride.namespace" -}}
{{- default .Release.Namespace .Values.namespace.name }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "rent-a-ride.labels" -}}
helm.sh/chart: {{ include "rent-a-ride.chart" . }}
{{ include "rent-a-ride.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels shared by a component's Deployment/StatefulSet/Service/HPA.
Pass a dict with "root" (the top-level context) and "component" (e.g. "mongo").
*/}}
{{- define "rent-a-ride.componentSelectorLabels" -}}
app: {{ .component }}
{{- end }}

{{/*
Base selector labels (chart-level, unused for pod selection to preserve
the original manifests' bare `app: <name>` selectors, which Deployments/
StatefulSets/Services/HPAs all still need to agree on).
*/}}
{{- define "rent-a-ride.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rent-a-ride.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Mongo host. Uses mongo.config.host if explicitly set, otherwise derives
the standard per-pod StatefulSet DNS name from mongo.name / the release
namespace, matching the original ConfigMap's MONGO_HOST value.
*/}}
{{- define "rent-a-ride.mongoHost" -}}
{{- if .Values.mongo.config.host }}
{{- .Values.mongo.config.host }}
{{- else }}
{{- printf "%s-0.%s.%s.svc.cluster.local" .Values.mongo.name .Values.mongo.name (include "rent-a-ride.namespace" .) }}
{{- end }}
{{- end }}
