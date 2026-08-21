{{/*
The container spec shared by every workload. Split out because Deployments and
StatefulSets differ only in how their storage is declared, not in what runs.

Args: dict "root" $ "w" <workload entry>
*/}}
{{- define "demo-workloads.container" -}}
{{- $root := .root -}}
{{- $w := .w -}}
{{- $d := $root.Values.defaults -}}
- name: app
  image: "{{ $root.Values.image.repository }}:{{ $root.Values.image.tag }}"
  imagePullPolicy: {{ $root.Values.image.pullPolicy }}
  env:
    - name: APP_NAME
      value: {{ $w.name | quote }}
{{- $listens := eq (include "demo-workloads.listens" $w) "true" }}
    - name: LISTEN_ADDR
      value: {{ if $listens }}":{{ default $d.port $w.port }}"{{ else }}""{{ end }}
    - name: UPSTREAMS
      value: {{ join "," (default (list) $w.upstreams) | quote }}
    # Connection strings, not URLs to call: each becomes a client span with no
    # server span, which the collector turns into a "://" peer and the backend
    # resolves to a real Service node.
    - name: DB_ENDPOINTS
      value: {{ join "," (default (list) $w.dbEndpoints) | quote }}
    - name: LATENCY
      value: {{ default $d.latency $w.latency | quote }}
    - name: ERROR_RATE
      value: {{ default $d.errorRate $w.errorRate | quote }}
    {{- if $w.callInterval }}
    - name: CALL_INTERVAL
      value: {{ $w.callInterval | quote }}
    {{- end }}
    {{- if $w.fillData }}
    - name: DATA_DIR
      value: {{ (default $w.pvc $w.storage).mountPath | quote }}
    {{- end }}
    # The pod UID is the whole point of the downward API here: the servicegraph
    # connector copies it onto every edge as client_k8s_pod_uid /
    # server_k8s_pod_uid, and that is the ONLY thing letting kube-state-graph
    # resolve a call edge to a pod rather than to an `external` node.
    - name: POD_UID
      valueFrom:
        fieldRef:
          fieldPath: metadata.uid
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: POD_NAMESPACE
      valueFrom:
        fieldRef:
          fieldPath: metadata.namespace
    - name: OTEL_EXPORTER_OTLP_ENDPOINT
      value: {{ $root.Values.otlpEndpoint | quote }}
    # service.name becomes the `client` / `server` label on the service-graph
    # series, i.e. the node label a viewer reads in the panel.
    - name: OTEL_RESOURCE_ATTRIBUTES
      value: "service.name={{ $w.name }},k8s.pod.uid=$(POD_UID),k8s.pod.name=$(POD_NAME),k8s.namespace.name=$(POD_NAMESPACE)"
  {{- if $listens }}
  ports:
    - name: http
      containerPort: {{ default $d.port $w.port }}
  livenessProbe:
    httpGet:
      path: /healthz
      port: http
  readinessProbe:
    httpGet:
      path: /healthz
      port: http
  {{- end }}
  {{- $mount := default $w.pvc $w.storage }}
  {{- if $mount }}
  volumeMounts:
    - name: data
      mountPath: {{ $mount.mountPath }}
  {{- end }}
  {{- with $root.Values.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: ["ALL"]
{{- end -}}
