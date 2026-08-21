#!/usr/bin/env bash
# Walk the pipeline hop by hop and say which one is empty.
#
# Almost every failure mode in this demo is silent: a missing label does not
# error, it just removes edges. So each check below asserts one precondition the
# backend depends on, in the order the data flows, and names what breaks when it
# is missing.
set -uo pipefail

VMSELECT="${1:-http://localhost:18481/select/0/prometheus}"
BACKEND="${2:-http://localhost:18080}"

pass=0
fail=0

# WINDOW matches how kube-state-graph itself reads: over a range, never at an
# instant. An instant query on a freshly-created series is legitimately empty
# for a scrape interval or two, which would make this script flap.
WINDOW="5m"

# query <label> <selector> <consequence-if-empty>
query() {
  query_expr "$1" "count(last_over_time($2[${WINDOW}]))" "$3"
}

# query_expr <label> <full-promql> <consequence-if-empty>
query_expr() {
  local label="$1" promql="$2" consequence="$3"
  local count
  count=$(curl -sS --max-time 20 --get "${VMSELECT}/api/v1/query" \
    --data-urlencode "query=${promql}" 2>/dev/null \
    | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)
  count=${count:-0}
  if [[ "${count}" == "0" || "${count}" == "null" ]]; then
    printf '  \033[31mFAIL\033[0m  %-46s %s\n' "${label}" "${consequence}"
    fail=$((fail + 1))
  else
    printf '  \033[32m ok \033[0m  %-46s %s series\n' "${label}" "${count}"
    pass=$((pass + 1))
  fi
}

echo
echo "== 1. kube-state-metrics reached VictoriaMetrics =="
query "kube_pod_info"                 'kube_pod_info'                                        "no pods in the graph at all"
query "kube_node_info"                'kube_node_info'                                       "no K8s node entities"
query "kube_persistentvolumeclaim_info" 'kube_persistentvolumeclaim_info'                    "no PVC nodes"

echo
echo "== 2. labels kube-state-metrics cannot produce (collector-stamped) =="
query "cluster label on pods"         'kube_pod_info{cluster!=""}'                           "every id falls into the 'unknown' cluster bucket"
query "az label on pods"              'kube_pod_info{az!=""}'                                "?az= returns an empty graph"
query "env label on pods"             'kube_pod_info{env!=""}'                              "?env= returns an empty graph"

echo
echo "== 3. non-default kube-state-metrics allowlists =="
query "endpointslice -> service join" 'kube_endpointslice_labels{label_kubernetes_io_service_name!=""}' "no service-selects-pod edges"
query "service ArgoCD annotation"     'kube_service_annotations{annotation_argocd_argoproj_io_tracking_id!=""}' "services carry no application"
query "pvc ArgoCD annotation"         'kube_persistentvolumeclaim_annotations{annotation_argocd_argoproj_io_tracking_id!=""}' "claims carry no application"

echo
echo "== 4. kubelet volume stats =="
query "kubelet_volume_stats_used"     'kubelet_volume_stats_used_bytes'                      "claims show no usage fill"

echo
echo "== 5. service-graph metrics from the OTLP traces =="
query "request_total"                 'traces_service_graph_request_total'                   "no call edges — the whole RED half is missing"
query "client_k8s_pod_uid populated"  'traces_service_graph_request_total{client_k8s_pod_uid!=""}' "call edges resolve to external nodes, not pods"
query "server_k8s_pod_uid populated"  'traces_service_graph_request_total{server_k8s_pod_uid!=""}' "server side of every call edge is external"
query "failed_total (error_rate)"     'traces_service_graph_request_failed_total'            "edges carry no errorRate"
query "server_seconds_bucket (p90)"   'traces_service_graph_request_server_seconds_bucket'   "edges carry no p90ServerMs"

echo
echo "== 6. the fake NetApp estate =="
query "volume_labels"                 'volume_labels'                                        "no storage topology: no aggregates, no controllers"
query "qos_read_ops"                  'qos_read_ops'                                         "storage edges exist but carry no I/O"
query "qos policy ceiling"            'qos_policy_fixed_max_throughput_iops'                 "storage edges carry no declared ceiling"
query "aggr_space_used"               'aggr_space_used'                                      "aggregates show no usage fill"
query_expr "volume_name joins a real PV" \
  'count(last_over_time(volume_labels[5m]) * on(volume_name) group_right() label_replace(last_over_time(kube_persistentvolumeclaim_info{volumename!=""}[5m]), "volume_name", "$1", "volumename", "(.+)"))' \
  "the fake estate hangs off nothing"

echo
echo "== 7. what the backend actually returns =="
now=$(date +%s)
graph=$(curl -sS --max-time 30 "${BACKEND}/v1/graph?start=$(( now - 300 ))&end=${now}&prune=false" 2>/dev/null)
if [[ -z "${graph}" ]] || ! jq -e '.elements' <<<"${graph}" >/dev/null 2>&1; then
  printf '  \033[31mFAIL\033[0m  %s\n' "the API returned nothing usable"
  fail=$((fail + 1))
else
  echo "  clusters: $(jq -c '.clusters' <<<"${graph}")"
  echo "  nodes by kind:"
  jq -r '[.elements.nodes[].data.type] | group_by(.) | map({(.[0]): length}) | add | to_entries[] | "    \(.key): \(.value)"' <<<"${graph}"
  echo "  edges by type:"
  jq -r '[.elements.edges[].data.type] | group_by(.) | map({(.[0]): length}) | add | to_entries[] | "    \(.key): \(.value)"' <<<"${graph}"
  echo "  edges carrying RED metrics: $(jq '[.elements.edges[] | select(.data.metrics != null)] | length' <<<"${graph}")"
  echo "  claims joined to a NetApp aggregate: $(jq '[.elements.edges[] | select(.data.type == "pvc-to-netapp-aggr")] | length' <<<"${graph}")"
  pass=$((pass + 1))
fi

echo
echo "${pass} ok, ${fail} failed"
exit $(( fail > 0 ? 1 : 0 ))
