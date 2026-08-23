#!/usr/bin/env bash
# Block until the demo is actually serving, not merely scheduled.
#
# `kubectl rollout status` per workload is not enough on a cold cluster: the
# graph only has content once metrics have been scraped at least once, so the
# last step waits for the backend to answer with a non-empty element set.
set -euo pipefail

ctx="${1:?usage: wait-ready.sh <kube-context> <namespace> [backend-url]}"
ns="${2:?usage: wait-ready.sh <kube-context> <namespace> [backend-url]}"
backend="${3:-http://localhost:18080}"
kubectl="kubectl --context ${ctx}"

echo "==> waiting for the platform namespace (${ns})"
${kubectl} -n "${ns}" wait --for=condition=Available --timeout=10m \
  deployment --all

# NFS CSI claims cannot bind until both the Ganesha export and the node plugin
# are up. The node plugin is a DaemonSet, so the Deployment wait above misses it.
if ${kubectl} -n "${ns}" get deploy nfs-server >/dev/null 2>&1; then
  ${kubectl} -n "${ns}" wait --for=condition=Available --timeout=10m deploy/nfs-server
fi
if ${kubectl} -n "${ns}" get ds csi-nfs-node >/dev/null 2>&1; then
  ${kubectl} -n "${ns}" rollout status ds/csi-nfs-node --timeout=10m
fi

echo "==> waiting for the demo workloads"
for workload_ns in shop platform; do
  # Enumerate rather than using --all: a namespace holding only StatefulSets
  # (platform does) makes `wait deployment --all` fail outright with
  # "no matching resources found", which is not an error here.
  for deploy in $(${kubectl} -n "${workload_ns}" get deployment -o name); do
    ${kubectl} -n "${workload_ns}" wait --for=condition=Available --timeout=10m "${deploy}"
  done
  # StatefulSets have no Available condition; roll them out one at a time.
  for sts in $(${kubectl} -n "${workload_ns}" get statefulset -o name); do
    ${kubectl} -n "${workload_ns}" rollout status "${sts}" --timeout=10m
  done
done

# Two independent storage signals have to land, and waiting on element count
# instead succeeds a minute too early and makes the very next `make verify` look
# broken.
#
#   1. A pvc-to-netapp-aggr edge — the longest chain in the demo
#      (kube-state-metrics → collector → VictoriaMetrics → netapp-faker discovery
#      → back into VictoriaMetrics → the backend's join).
#   2. Kubelet usage on every claim that joined — the CSI leg
#      (NodeGetVolumeStats → kubelet /metrics → collector → VictoriaMetrics →
#      the backend).
#
# Neither implies the other: the faker discovers claims from
# kube_persistentvolumeclaim_info and never reads a kubelet, so the join can be
# complete while the kubelet leg is still absent. It routinely is — the CSI node
# plugin answers NodeGetVolumeStats with `remote I/O error` for a minute or two
# after a cold bring-up, and the collector keeps only kubelet_volume_stats_*
# from that scrape job, so nothing at all arrives until it settles. Waiting on
# the join alone returned there and `make verify` failed three checks that were
# merely early.
echo "==> waiting for the storage chain (the last two hops to appear)"
# 10m to match the rollout waits above: the join and the kubelet leg are
# sequential in the worst case, and the kubelet leg only starts settling once
# the CSI node plugin stops erroring.
deadline=$(( $(date +%s) + 600 ))
while :; do
  now=$(date +%s)
  graph=$(curl -sS --max-time 20 \
    "${backend}/v1/graph?start=$(( now - 300 ))&end=${now}&prune=false" 2>/dev/null)
  nodes=$(jq '(.elements.nodes | length) + (.elements.edges | length)' <<<"${graph:-}" 2>/dev/null || echo 0)
  # Claims that reached an aggregate, and how many of those also carry kubelet
  # usage. Counting the measured ones against the joined ones needs no
  # StorageClass name: a claim only reaches an aggregate if it is on the demo's
  # class in the first place.
  joined=$(jq '[.elements.edges[] | select(.data.type == "pvc-to-netapp-aggr") | .data.source] | unique | length' \
    <<<"${graph:-}" 2>/dev/null || echo 0)
  measured=$(jq '
      ([.elements.edges[] | select(.data.type == "pvc-to-netapp-aggr") | .data.source] | unique) as $joined
      | [ .elements.nodes[]
          | select(.data.type == "pvc")
          | select(.data.usage.used_bytes != null)
          | .data.id
          | select(. as $id | $joined | index($id)) ]
      | length' <<<"${graph:-}" 2>/dev/null || echo 0)
  if [[ "${joined}" =~ ^[0-9]+$ ]] && [[ "${measured}" =~ ^[0-9]+$ ]] &&
     (( joined > 0 )) && (( measured == joined )); then
    echo "    graph has ${nodes} elements, ${joined} claims joined to a NetApp aggregate, all ${measured} carrying kubelet usage"
    break
  fi
  if (( now > deadline )); then
    echo "    after 10 minutes: ${joined:-0} claims joined to an aggregate, ${measured:-0} of them carrying kubelet usage" >&2
    echo "    run 'make verify' to see which hop is missing" >&2
    exit 1
  fi
  sleep 10
done
