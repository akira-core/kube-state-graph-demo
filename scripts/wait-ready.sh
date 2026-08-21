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

# Wait for a pvc-to-netapp-aggr edge specifically, not merely for a non-empty
# graph. That one edge is the longest chain in the demo — kube-state-metrics →
# collector → VictoriaMetrics → netapp-faker discovery → back into
# VictoriaMetrics → the backend's join — so it is the last thing to appear and
# proves every hop en route. Waiting on element count instead succeeds a minute
# too early and makes the very next `make verify` look broken.
echo "==> waiting for the storage join (the last hop to appear)"
deadline=$(( $(date +%s) + 300 ))
while :; do
  now=$(date +%s)
  graph=$(curl -sS --max-time 20 \
    "${backend}/v1/graph?start=$(( now - 300 ))&end=${now}&prune=false" 2>/dev/null)
  nodes=$(jq '(.elements.nodes | length) + (.elements.edges | length)' <<<"${graph:-}" 2>/dev/null || echo 0)
  storage=$(jq '[.elements.edges[] | select(.data.type == "pvc-to-netapp-aggr")] | length' <<<"${graph:-}" 2>/dev/null || echo 0)
  if [[ "${storage}" =~ ^[0-9]+$ ]] && (( storage > 0 )); then
    echo "    graph has ${nodes} elements, ${storage} claims joined to a NetApp aggregate"
    break
  fi
  if (( now > deadline )); then
    echo "    no storage edges after 5 minutes — run 'make verify' to see which hop is missing" >&2
    exit 1
  fi
  sleep 10
done
