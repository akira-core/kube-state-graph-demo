{{- define "demo-workloads.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: ksg-demo
{{- end -}}

{{/*
The ArgoCD tracking id kube-state-graph parses for `data.application`. It reads
the segment before the FIRST colon and ignores the rest, so the tail only has to
look like the real thing. Stamped on the resources ArgoCD would apply
(controller, Service, PVC) — never on the pods a controller spawns.

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
The pod labels the backend's optional application-metadata metric is read from.
kube-state-metrics exports them on kube_pod_labels as label_<name>, and the
backend binds app / user / ns_owner to label_argocd_app / label_user /
label_owner (`kube-state-graph.appMetadata.labels` in the umbrella values).

  owner       every pod of a namespace carries its namespace's owner. A row needs
              no app for this one, so it reaches the namespace group even from
              a pod whose Application the controller chain resolves.
  argocd_app  only on a workload that sets `deployedBy`. The metric's app WINS
              over the controller-annotation chain for that pod and is used
              verbatim, so it is the SAME bare name the tracking id carries.
  user        the deployer, keyed by (namespace, the row's own app). A row with
              no app contributes none, hence the pairing with argocd_app.

A workload that sets no `deployedBy` keeps the controller chain for its
Application: that is the control case, and it is what keeps `make verify` able
to see a dropped tracking-id allowlist.

Args: dict "root" $ "w" <workload entry>
*/}}
{{- define "demo-workloads.appMetadataLabels" -}}
{{- $owner := index (default (dict) .root.Values.appMetadata.owners) .w.namespace -}}
{{- if $owner }}
owner: {{ $owner | quote }}
{{- end }}
{{- if .w.deployedBy }}
argocd_app: {{ .w.application | quote }}
user: {{ .w.deployedBy | quote }}
{{- end }}
{{- end -}}

{{/*
Whether a workload runs an inbound listener. Absent means yes.

A plain `default true .listen` cannot express this: Helm's `default` treats
false as empty, so an explicit `listen: false` would silently become true.
*/}}
{{- define "demo-workloads.listens" -}}
{{- if kindIs "bool" .listen }}{{ .listen }}{{ else }}true{{ end -}}
{{- end -}}
