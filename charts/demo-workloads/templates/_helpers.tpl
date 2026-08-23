{{- define "demo-workloads.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: ksg-demo
{{- end -}}

{{/*
The ArgoCD tracking id kube-state-graph parses for `data.application`. It reads
the segment before the FIRST colon and ignores the rest, so the tail only has to
look like the real thing.

Args: dict "app" <application> "kind" <Kind> "ns" <namespace> "name" <name>
*/}}
{{- define "demo-workloads.trackingID" -}}
{{ .app }}:/{{ .kind }}:{{ .ns }}/{{ .name }}
{{- end -}}

{{/*
Per-workload pod labels. `app.kubernetes.io/name` doubles as the Service
selector, so it must be unique per workload within a namespace.
*/}}
{{- define "demo-workloads.podLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .application }}
demo.ksg.io/application: {{ .application }}
{{- end -}}

{{/*
Whether a workload runs an inbound listener. Absent means yes.

A plain `default true .listen` cannot express this: Helm's `default` treats
false as empty, so an explicit `listen: false` would silently become true.
*/}}
{{- define "demo-workloads.listens" -}}
{{- if kindIs "bool" .listen }}{{ .listen }}{{ else }}true{{ end -}}
{{- end -}}
