#!/usr/bin/env bash
# Walk the pipeline hop by hop and say which one is empty.
#
# Almost every failure mode in this demo is silent: a missing label does not
# error, it just removes edges. So each check below asserts one precondition the
# backend depends on, in the order the data flows, and names what breaks when it
# is missing.
set -uo pipefail

# The demo keeps its metrics in TWO Prometheus-compatible stores and
# kube-state-graph's routing table is what assembles one graph from both. Every
# check below therefore has to say WHICH store it is asking: a query sent to
# the wrong one returns an empty result that looks exactly like a broken
# pipeline, which is the confusion this script exists to remove.
#
#   cluster store  vmselect, unauthenticated  — NetApp Harvest, service-graph
#   single store   vmauth, basic auth         — kube-state-metrics, kubelet
VMSELECT="${1:-http://localhost:18481/select/0/prometheus}"
BACKEND="${2:-http://localhost:18080}"
VMAUTH="${3:-http://localhost:18427}"
VMAUTH_USER="${4:-ksg}"
VMAUTH_PASS="${5:-ksg-demo-not-a-real-secret}"
# The front door. Sections 10 and 11 go THROUGH it rather than straight to the
# backend or the store, because the same-origin proxying is itself under test.
FRONTEND="${6:-http://localhost:3001}"

# Must match global.ksgExternalLabels. The backend composes
# <az>-<env>-<cluster> as the identity; ?cluster= still takes the raw name.
KSG_CLUSTER_RAW="ksg-demo"
KSG_AZ="local-a"
KSG_ENV="demo"
KSG_CLUSTER_IDENTITY="${KSG_AZ}-${KSG_ENV}-${KSG_CLUSTER_RAW}"

pass=0
fail=0

# WINDOW matches how kube-state-graph itself reads: over a range, never at an
# instant. An instant query on a freshly-created series is legitimately empty
# for a scrape interval or two, which would make this script flap.
WINDOW="5m"

# Which store the next block of checks asks. Set by use_store, read by the
# three helpers below, and named in every section header so a failure says
# where to go looking.
STORE_URL="${VMSELECT}"
STORE_AUTH=()

# use_store cluster|single
use_store() {
  case "$1" in
    cluster) STORE_URL="${VMSELECT}"; STORE_AUTH=() ;;
    single)  STORE_URL="${VMAUTH}";   STORE_AUTH=(--user "${VMAUTH_USER}:${VMAUTH_PASS}") ;;
    *) echo "use_store: unknown store $1" >&2; exit 2 ;;
  esac
}

# scalar <full-promql> — the single value an instant query resolved to, or 0.
scalar() {
  # ${arr[@]+...} rather than a bare ${arr[@]}: bash 3.2 (what macOS ships)
  # treats expanding an EMPTY array as an unbound variable under `set -u`.
  curl -sS --max-time 20 ${STORE_AUTH[@]+"${STORE_AUTH[@]}"} --get "${STORE_URL}/api/v1/query" \
    --data-urlencode "query=$1" 2>/dev/null \
    | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null
}

# query <label> <selector> <consequence-if-empty>
query() {
  query_expr "$1" "count(last_over_time($2[${WINDOW}]))" "$3"
}

# query_absent <label> <full-promql> <consequence-if-nonzero>
# Inverse of query_expr: the PromQL must resolve to 0. Used for negative
# proofs (no simulated kubelet series, etc.).
query_absent() {
  local label="$1" promql="$2" consequence="$3"
  local count
  count=$(scalar "${promql}")
  count=${count:-0}
  if [[ "${count}" != "0" && "${count}" != "null" ]]; then
    printf '  \033[31mFAIL\033[0m  %-46s %s (%s series)\n' "${label}" "${consequence}" "${count}"
    fail=$((fail + 1))
  else
    printf '  \033[32m ok \033[0m  %-46s 0 series\n' "${label}"
    pass=$((pass + 1))
  fi
}

# query_expr <label> <full-promql> <consequence-if-empty>
query_expr() {
  local label="$1" promql="$2" consequence="$3"
  local count
  count=$(scalar "${promql}")
  count=${count:-0}
  if [[ "${count}" == "0" || "${count}" == "null" ]]; then
    printf '  \033[31mFAIL\033[0m  %-46s %s\n' "${label}" "${consequence}"
    fail=$((fail + 1))
  else
    printf '  \033[32m ok \033[0m  %-46s %s series\n' "${label}" "${count}"
    pass=$((pass + 1))
  fi
}

# check <label> <ok?> <detail> — for assertions that are not a PromQL count.
check() {
  if [[ "$2" == "yes" ]]; then
    printf '  \033[32m ok \033[0m  %-46s %s\n' "$1" "$3"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  %-46s %s\n' "$1" "$3"
    fail=$((fail + 1))
  fi
}

use_store single
echo
echo "== 1. kube-state-metrics reached the SINGLE-NODE store (via vmauth) =="
query "kube_pod_info"                 'kube_pod_info'                                        "no pods in the graph at all"
query "kube_node_info"                'kube_node_info'                                       "no K8s node entities"
query "kube_persistentvolumeclaim_info" 'kube_persistentvolumeclaim_info'                    "no PVC nodes"

echo
echo "== 2. labels kube-state-metrics cannot produce (vmagent-stamped) =="
query "cluster label on pods"         'kube_pod_info{cluster!=""}'                           "every id falls into the 'unknown' cluster bucket"
query "az label on pods"              'kube_pod_info{az!=""}'                                "?az= returns an empty graph"
query "env label on pods"             'kube_pod_info{env!=""}'                              "?env= returns an empty graph"

echo
echo "== 3. non-default kube-state-metrics allowlists =="
query "endpointslice -> service join" 'kube_endpointslice_labels{label_kubernetes_io_service_name!=""}' "no service-selects-pod edges"
query "service ArgoCD annotation"     'kube_service_annotations{annotation_argocd_argoproj_io_tracking_id!=""}' "services carry no application"
query "pvc ArgoCD annotation"         'kube_persistentvolumeclaim_annotations{annotation_argocd_argoproj_io_tracking_id!=""}' "claims carry no application"
query "deployment ArgoCD annotation"  'kube_deployment_annotations{annotation_argocd_argoproj_io_tracking_id!=""}' "Deployment-owned pods nest under controller, no application group"
query "statefulset ArgoCD annotation" 'kube_statefulset_annotations{annotation_argocd_argoproj_io_tracking_id!=""}' "StatefulSet-owned pods nest under controller, no application group"

echo
echo "== 4. kubelet volume stats (real, vmagent-scraped and -stamped) =="
query "kubelet_volume_stats_used"     'kubelet_volume_stats_used_bytes'                      "claims show no usage fill"
query "kubelet used carries az"       'kubelet_volume_stats_used_bytes{az!=""}'               "filtered ?az= drops claim usage"
query "kubelet used carries env"      'kubelet_volume_stats_used_bytes{env!=""}'              "filtered ?env= drops claim usage"
query_absent "no simulated volume stats" \
  'count(last_over_time(kubelet_volume_stats_used_bytes['"${WINDOW}"']) unless last_over_time(kubelet_volume_stats_used_bytes{job="kubelet"}['"${WINDOW}"']))' \
  "a non-kubelet job is publishing kubelet_volume_stats_* again"

use_store cluster
echo
echo "== 5. service-graph metrics from the OTLP traces (CLUSTER store) =="
query "request_total"                 'traces_service_graph_request_total'                   "no call edges — the whole RED half is missing"
query "client_k8s_pod_uid populated"  'traces_service_graph_request_total{client_k8s_pod_uid!=""}' "call edges resolve to external nodes, not pods"
query "server_k8s_pod_uid populated"  'traces_service_graph_request_total{server_k8s_pod_uid!=""}' "server side of every call edge is external"
query "failed_total (error_rate)"     'traces_service_graph_request_failed_total'            "edges carry no errorRate"
query "server_seconds_bucket (p90)"   'traces_service_graph_request_server_seconds_bucket'   "edges carry no p90ServerMs"

echo
echo "== 6. the fake NetApp estate (CLUSTER store) =="
query "volume_labels"                 'volume_labels'                                        "no storage topology: no aggregates, no controllers"
query "qos_read_ops"                  'qos_read_ops'                                         "storage edges exist but carry no I/O"
query "qos policy ceiling"            'qos_policy_fixed_max_throughput_iops'                 "storage edges carry no declared ceiling"
query "aggr_space_used"               'aggr_space_used'                                      "aggregates show no usage fill"
echo
echo "== 7. the split is real, and the join spans it =="
# This used to be one PromQL expression joining volume_labels to
# kube_persistentvolumeclaim_info inside vmselect. It cannot be: the two halves
# now live in different stores, and no single store can join across them. That
# is the whole point — assembling this join is kube-state-graph's job, and
# section 9 asserts the edge it produces. Here we only prove the two halves
# exist, on the two sides, and refer to the same PV names.

harvest_pvs=$(curl -sS --max-time 20 --get "${VMSELECT}/api/v1/query" \
  --data-urlencode "query=last_over_time(volume_labels[${WINDOW}])" 2>/dev/null \
  | jq -r '.data.result[]?.metric.volume_name // empty' | sort -u)

k8s_pvs=$(curl -sS --max-time 20 --user "${VMAUTH_USER}:${VMAUTH_PASS}" \
  --get "${VMAUTH}/api/v1/query" \
  --data-urlencode "query=last_over_time(kube_persistentvolumeclaim_info{volumename!=\"\"}[${WINDOW}])" 2>/dev/null \
  | jq -r '.data.result[]?.metric.volumename // empty' | sort -u)

shared=$(comm -12 <(printf '%s\n' "${harvest_pvs}") <(printf '%s\n' "${k8s_pvs}") | grep -c . || true)
if [[ "${shared}" -gt 0 ]]; then
  check "volume_name joins a real PV across stores" yes "${shared} PV names in both stores"
else
  check "volume_name joins a real PV across stores" no \
    "the fake estate hangs off nothing ($(grep -c . <<<"${harvest_pvs}") harvest / $(grep -c . <<<"${k8s_pvs}") k8s PV names)"
fi

# Negative proofs that the two stores hold DIFFERENT things. Without these, a
# misconfiguration that wrote everything to both would leave every check above
# green while the routing table did nothing at all.
use_store cluster
query_absent "cluster store holds no kube_pod_info" \
  "count(last_over_time(kube_pod_info[${WINDOW}]))" \
  "kube-state-metrics is reaching BOTH stores — the split is not real"
use_store single
query_absent "single store holds no volume_labels" \
  "count(last_over_time(volume_labels[${WINDOW}]))" \
  "the faker is writing to BOTH stores — the split is not real"

# vmauth is what makes the routing table's credential legs load-bearing. If it
# answered unauthenticated reads, usernameEnv / passwordEnv could be wrong and
# nothing would notice.
code=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
  --get "${VMAUTH}/api/v1/query" --data-urlencode 'query=up' 2>/dev/null || echo 000)
if [[ "${code}" == "401" ]]; then
  check "vmauth rejects an unauthenticated read" yes "HTTP 401"
else
  check "vmauth rejects an unauthenticated read" no \
    "HTTP ${code} — the backend's credentials are not actually required"
fi

echo
echo "== 8. upstream backend routing =="
# Read from the backend's own /metrics rather than inferred from the graph: a
# backend that silently stopped being queried still leaves the graph looking
# plausible, just smaller.
metrics=$(curl -sS --max-time 20 "${BACKEND}/metrics" 2>/dev/null || true)
if [[ -z "${metrics}" ]]; then
  check "backend /metrics" no "returned nothing"
else
  n=$(awk '$1 == "kube_state_graph_upstream_backends" { print $2 }' <<<"${metrics}" | tail -1)
  if [[ "${n%.*}" == "2" ]]; then
    check "routing table has both backends" yes "kube_state_graph_upstream_backends = 2"
  else
    check "routing table has both backends" no \
      "kube_state_graph_upstream_backends = ${n:-<absent>}, expected 2"
  fi

  # Per-backend failures, measured as the DELTA across one graph build rather
  # than as an absolute. The counter is cumulative since process start, and a
  # cold bring-up reliably puts tens of connection-refused errors in it: the
  # server is ready before either store is. Those are history. What matters is
  # whether the build happening now touches both stores without error.
  #
  # The series is materialised at zero for every configured backend, so an
  # ABSENT one still means "not in the live table" and is failed as such.
  backend_failures() {
    grep -F "kube_state_graph_backend_query_failures_total{backend=\"$1\"}" <<<"$2" \
      | tail -1 | awk '{ print $2 }'
  }

  missing=0
  for backend in cluster-store single-store; do
    if [[ -z "$(backend_failures "${backend}" "${metrics}")" ]]; then
      check "backend ${backend} is in the live table" no "no failure series — it is not being routed to"
      missing=$((missing + 1))
    else
      check "backend ${backend} is in the live table" yes "present"
    fi
  done

  if [[ "${missing}" == "0" ]]; then
    curl -sS --max-time 30 -o /dev/null \
      "${BACKEND}/v1/graph?start=$(( $(date +%s) - 300 ))&end=$(date +%s)&prune=false" 2>/dev/null || true
    after=$(curl -sS --max-time 20 "${BACKEND}/metrics" 2>/dev/null || true)
    for backend in cluster-store single-store; do
      before_n=$(backend_failures "${backend}" "${metrics}")
      after_n=$(backend_failures "${backend}" "${after}")
      delta=$(awk -v a="${after_n:-0}" -v b="${before_n:-0}" 'BEGIN { printf "%d", a - b }')
      if [[ "${delta}" == "0" ]]; then
        check "backend ${backend} failures during one build" yes "0 new (${before_n%.*} lifetime)"
      else
        check "backend ${backend} failures during one build" no \
          "${delta} new failures — that store is not answering"
      fi
    done
  fi

  reload_err=$(awk '/^kube_state_graph_backend_config_reload_total\{result="error"\}/ { print $2 }' <<<"${metrics}" | tail -1)
  if [[ -z "${reload_err}" || "${reload_err%.*}" == "0" ]]; then
    check "routing file reloads cleanly" yes "0 errors"
  else
    check "routing file reloads cleanly" no "${reload_err} rejected reloads — the mounted file is invalid"
  fi
fi

# /readyz probes EVERY backend serving the probe family, which is why both
# entries list it. A 200 here means both stores answered.
code=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "${BACKEND}/readyz" 2>/dev/null || echo 000)
if [[ "${code}" == "200" ]]; then
  check "/readyz — every backend answered" yes "HTTP 200"
else
  check "/readyz — every backend answered" no "HTTP ${code}"
fi

echo
echo "== 9. what the backend actually returns =="
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
  pass=$((pass + 1))

  # The cross-store assertion. Its two halves are kube_persistentvolumeclaim_info
  # in the single-node store and volume_labels in the cluster store, and no
  # PromQL can join them — only the backend's fan-out and merge can. A zero here
  # with both halves present (section 7) means the routing table is wrong.
  joined=$(jq '[.elements.edges[] | select(.data.type == "pvc-to-netapp-aggr")] | length' <<<"${graph}")
  if [[ "${joined}" != "0" ]]; then
    check "pvc-to-netapp-aggr (join across both stores)" yes "${joined} edges"
  else
    check "pvc-to-netapp-aggr (join across both stores)" no \
      "no claim reached an aggregate — the two stores are not being merged"
  fi

  # Pod application is joined from the controller annotation, not from a
  # synthesised kube_pod_owner label. shop/platform are the estate the demo
  # stamps; monitoring pods have no tracking-id and correctly stay ungrouped.
  app_groups=$(jq '[.elements.nodes[] | select(.data.type == "application")] | length' <<<"${graph}")
  unapp=$(jq '[.elements.nodes[] | select(.data.type == "pod") | select(.data.labels.namespace == "shop" or .data.labels.namespace == "platform") | select((.data.application // "") == "")] | length' <<<"${graph}")
  if [[ "${app_groups}" == "0" ]]; then
    printf '  \033[31mFAIL\033[0m  %-46s %s\n' "application group nodes" "controller tracking-id did not join"
    fail=$((fail + 1))
  else
    printf '  \033[32m ok \033[0m  %-46s %s nodes\n' "application group nodes" "${app_groups}"
    pass=$((pass + 1))
  fi
  if [[ "${unapp}" != "0" ]]; then
    printf '  \033[31mFAIL\033[0m  %-46s %s missing data.application\n' "shop/platform pod application" "${unapp}"
    fail=$((fail + 1))
  else
    printf '  \033[32m ok \033[0m  %-46s all carry data.application\n' "shop/platform pod application"
    pass=$((pass + 1))
  fi

  # Cluster identity is <az>-<env>-<cluster>. A build that still keys on the
  # raw name (or whose stampers disagree) is a silently-wrong graph: ids
  # collide across zones and ?cluster= round-trips from clusters[] stop
  # working. The three request dimensions ARE the identity's components.
  got_clusters=$(jq -c '.clusters' <<<"${graph}")
  if [[ "${got_clusters}" == "[\"${KSG_CLUSTER_IDENTITY}\"]" ]]; then
    check "clusters[] is the composed identity" yes "${got_clusters}"
  else
    check "clusters[] is the composed identity" no \
      "got ${got_clusters}, expected [\"${KSG_CLUSTER_IDENTITY}\"] — stampers disagree or identity did not compose"
  fi

  raw_on_elements=$(jq --arg raw "${KSG_CLUSTER_RAW}" \
    '[.elements.nodes[], .elements.edges[] | select(.data.labels.cluster == $raw)] | length' \
    <<<"${graph}")
  if [[ "${raw_on_elements}" == "0" ]]; then
    check "no element carries the raw cluster label" yes \
      "${KSG_CLUSTER_RAW} is the ?cluster= value, not labels.cluster"
  else
    check "no element carries the raw cluster label" no \
      "${raw_on_elements} elements still labelled ${KSG_CLUSTER_RAW}"
  fi

  raw_filtered=$(curl -sS --max-time 30 \
    "${BACKEND}/v1/graph?start=$(( now - 300 ))&end=${now}&prune=false&cluster=${KSG_CLUSTER_RAW}" \
    2>/dev/null)
  raw_nodes=$(jq '[.elements.nodes[]?] | length' <<<"${raw_filtered}" 2>/dev/null || echo 0)
  if [[ "${raw_nodes}" != "0" && "${raw_nodes}" != "null" ]]; then
    check "?cluster=${KSG_CLUSTER_RAW} (raw name) still loads" yes "${raw_nodes} nodes"
  else
    check "?cluster=${KSG_CLUSTER_RAW} (raw name) still loads" no \
      "empty — projection is matching the identity instead of the raw component"
  fi

  identity_filtered=$(curl -sS --max-time 30 \
    "${BACKEND}/v1/graph?start=$(( now - 300 ))&end=${now}&prune=false&cluster=${KSG_CLUSTER_IDENTITY}" \
    2>/dev/null)
  identity_nodes=$(jq '[.elements.nodes[]?] | length' <<<"${identity_filtered}" 2>/dev/null || echo 0)
  identity_clusters=$(jq -c '.clusters // []' <<<"${identity_filtered}" 2>/dev/null || echo '[]')
  if [[ "${identity_nodes}" == "0" && "${identity_clusters}" == "[]" ]]; then
    check "?cluster=<identity> is empty (not a filter value)" yes "200 with empty elements"
  else
    check "?cluster=<identity> is empty (not a filter value)" no \
      "${identity_nodes} nodes / clusters ${identity_clusters} — identity leaked into ?cluster="
  fi
fi

echo
echo "== 10. the front door serves its config and reaches the backend through itself =="
# The SPA fetches <origin>/config.json on every full page load and then asks for
# exactly what that file names. Both halves are asserted here, and the graph
# request goes through the FRONT DOOR's origin, not straight to the backend:
# a 404 from the proxy is the empty-canvas failure this demo exists to catch,
# and it is invisible from the backend side.
code=$(curl -sS --max-time 20 -o /tmp/ksg-verify-config.json -w '%{http_code}' \
  "${FRONTEND}/config.json" 2>/dev/null || echo 000)
if [[ "${code}" == 200 ]] && jq -e . /tmp/ksg-verify-config.json >/dev/null 2>&1; then
  check "front door serves a parseable /config.json" yes "HTTP ${code}"
else
  check "front door serves a parseable /config.json" no \
    "HTTP ${code} — the ConfigMap is not mounted, or nginx is not serving /srv/config"
fi

if jq -e '.demoMode == false' /tmp/ksg-verify-config.json >/dev/null 2>&1; then
  check "front door is NOT in demo mode" yes "demoMode=false"
else
  check "front door is NOT in demo mode" no \
    "demoMode is not false — the SPA would draw its own bundled fixture, which proves nothing"
fi

# Health does not read the config or the backend, so it separates "the server is
# down" from "the pipeline is down".
code=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "${FRONTEND}/healthz" 2>/dev/null || echo 000)
check "front door answers /healthz" "$( [[ "${code}" == 200 ]] && echo yes || echo no )" "HTTP ${code}"

graph_path=$(jq -r '.endpoints.graph // empty' /tmp/ksg-verify-config.json 2>/dev/null || true)
if [[ -z "${graph_path}" ]]; then
  check "config names a graph endpoint" no "endpoints.graph is absent — the SPA cannot load at all"
else
  # Unpruned, like every other graph request this script makes: the default
  # projection returns only connectivity-connected workload, and this script
  # counts the inventory.
  code=$(curl -sS --max-time 30 -o /tmp/ksg-verify-fe-graph.json -w '%{http_code}' \
    "${FRONTEND}${graph_path}?start=$(( now - 300 ))&end=${now}&prune=false" 2>/dev/null || echo 000)
  elems=$(jq '(.elements.nodes | length) + (.elements.edges | length)' /tmp/ksg-verify-fe-graph.json 2>/dev/null || echo 0)
  if [[ "${code}" == 200 ]] && [[ "${elems}" =~ ^[0-9]+$ ]] && (( elems > 0 )); then
    check "graph answers through the front door (${graph_path})" yes "HTTP ${code}, ${elems} elements"
  else
    check "graph answers through the front door (${graph_path})" no \
      "HTTP ${code}, ${elems} elements — nginx /api/ is not reaching kube-state-graph"
  fi
fi

# The catalogue that validates ?edge_type=. The SPA populates its edge-type
# control from it, so a control offering a value this does not list would be a
# 400 rather than a narrowed graph.
edge_path=$(jq -r '.endpoints.edgeTypes // empty' /tmp/ksg-verify-config.json 2>/dev/null || true)
if [[ -n "${edge_path}" ]]; then
  types=$(curl -sS --max-time 20 "${FRONTEND}${edge_path}" 2>/dev/null | jq -r '[.edge_types[].type] | length' 2>/dev/null || echo 0)
  if [[ "${types}" =~ ^[0-9]+$ ]] && (( types > 0 )); then
    check "edge-type catalogue answers through the front door" yes "${types} registered types"
  else
    check "edge-type catalogue answers through the front door" no \
      "no types returned — the edge-type control would be empty"
  fi
fi

echo
echo "== 11. filter options come from the SINGLE-NODE store, through the front door =="
# The four identity controls read kube_pod_info label values. They must reach
# the store that HOLDS that family (single-node, behind vmauth) and they must
# offer the RAW cluster name: the graph response's clusters[] is the composed
# <az>-<env>-<cluster> identity, and feeding that back as ?cluster= returns an
# empty 200 — a filter that appears to work and moves nothing.
#
# The credential is attached by the front door's nginx, in-cluster. This curl
# deliberately sends none: if it needed one, so would the browser.
lv_base=$(jq -r '.endpoints.labelValues // empty' /tmp/ksg-verify-config.json 2>/dev/null || true)
if [[ -z "${lv_base}" ]]; then
  check "config names a label-values endpoint" no \
    "endpoints.labelValues is absent — the identity controls would be empty"
else
  for dim in cluster az env namespace; do
    body=$(curl -sS --max-time 20 \
      "${FRONTEND}${lv_base}/api/v1/label/${dim}/values?match[]=kube_pod_info" 2>/dev/null || true)
    count=$(jq -r '.data | length' <<<"${body}" 2>/dev/null || echo 0)
    if jq -e '.status == "success"' <<<"${body}" >/dev/null 2>&1 && [[ "${count}" =~ ^[0-9]+$ ]] && (( count > 0 )); then
      check "\$${dim} options via the front door" yes "$(jq -c '.data' <<<"${body}")"
    else
      check "\$${dim} options via the front door" no \
        "$(jq -c '.' <<<"${body}" 2>/dev/null || echo "unreadable") — no credential attached, or the wrong store"
    fi
  done

  clusters=$(curl -sS --max-time 20 \
    "${FRONTEND}${lv_base}/api/v1/label/cluster/values?match[]=kube_pod_info" 2>/dev/null || true)
  if jq -e --arg raw "${KSG_CLUSTER_RAW}" '.data | index($raw) != null' <<<"${clusters}" >/dev/null 2>&1; then
    check "cluster control offers the raw ${KSG_CLUSTER_RAW}" yes "$(jq -c '.data' <<<"${clusters}")"
  else
    check "cluster control offers the raw ${KSG_CLUSTER_RAW}" no \
      "$(jq -c '.data' <<<"${clusters}" 2>/dev/null || echo "unreadable") — the control would select nothing"
  fi
  if jq -e --arg id "${KSG_CLUSTER_IDENTITY}" '.data | index($id) == null' <<<"${clusters}" >/dev/null 2>&1; then
    check "cluster control does NOT offer ${KSG_CLUSTER_IDENTITY}" yes "composed identity absent, as it must be"
  else
    check "cluster control does NOT offer ${KSG_CLUSTER_IDENTITY}" no \
      "the composed identity is being offered as a filter value — it matches no series"
  fi
fi

echo
echo "${pass} ok, ${fail} failed"
exit $(( fail > 0 ? 1 : 0 ))
