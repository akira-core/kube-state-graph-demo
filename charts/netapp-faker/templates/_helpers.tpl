{{- define "netapp-faker.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "netapp-faker.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "netapp-faker.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "netapp-faker.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "netapp-faker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "netapp-faker.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netapp-faker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Render the external-label map as the `k=v,k=v` form the faker parses. Sorted so
a values reordering does not churn the pod spec and trigger a needless rollout.
*/}}
{{- define "netapp-faker.extraLabels" -}}
{{- $pairs := list -}}
{{- range $k, $v := .Values.extraLabels -}}
{{- $pairs = append $pairs (printf "%s=%s" $k $v) -}}
{{- end -}}
{{- join "," (sortAlpha $pairs) -}}
{{- end -}}
