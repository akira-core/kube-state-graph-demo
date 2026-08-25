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

`global.ksgExternalLabels.az` / `.env` seed the map when the umbrella release
supplies them, because the faker is the THIRD component stamping those two
labels — vmagent stamps what it scrapes and the collector stamps the
service-graph series — and kube-state-graph pushes ?az= / ?env= to upstream
PromQL as raw matchers against every family, this one included. A value that
disagreed with the other two would silently drop the whole NetApp estate out of
any filtered request. `extraLabels` still wins per key, and a standalone install
with no `global` gets exactly what it declares.

`cluster` is deliberately NOT seeded: Harvest series carry no cluster label, and
inventing one would put the storage estate in a cluster bucket of its own.
*/}}
{{- define "netapp-faker.extraLabels" -}}
{{- $labels := dict -}}
{{- with (.Values.global).ksgExternalLabels -}}
{{- $src := . -}}
{{- range $k := list "az" "env" -}}
{{- with (get $src $k) -}}{{- $_ := set $labels $k . -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- range $k, $v := .Values.extraLabels -}}
{{- $_ := set $labels $k $v -}}
{{- end -}}
{{- $pairs := list -}}
{{- range $k, $v := $labels -}}
{{- $pairs = append $pairs (printf "%s=%s" $k $v) -}}
{{- end -}}
{{- join "," (sortAlpha $pairs) -}}
{{- end -}}
