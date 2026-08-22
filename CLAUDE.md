# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

An **integration repository**, not a product. It stands up `kube-state-graph`
(Go API server) and `kube-state-graph-panel` (Grafana panel plugin) on a local
kind cluster, together with the whole metrics pipeline they need, and proves the
graph draws end to end.

The only first-party code here is `tools/` (two throwaway Go binaries). Everything
else is Helm values, Dockerfiles and shell — the repository's substance is
**wiring**, and most changes are one-line values edits whose failure mode is a
silently missing edge rather than an error.

`README.md` is the narrative explanation (pipeline diagram, what is real vs faked,
every edge type, troubleshooting table). Read it before changing pipeline wiring.

## Submodules

`kube-state-graph/` and `kube-state-graph-panel/` are git submodules pinned to
**feature branches**, not `main`:

| Submodule | Tracked branch |
|---|---|
| `kube-state-graph` | `replace-storageclass-with-netapp-nodes` |
| `kube-state-graph-panel` | `sync-netapp-storage-nodes` |

Each has its own `CLAUDE.md` with its own conventions — read the relevant one
before editing inside it. Changes inside a submodule belong to *that* repository:
commit there first, then commit the moved pointer here. Never commit a submodule
pointer change without saying which upstream commit it moves to.

To demo an unpushed change from a working copy outside this repo, do not touch
the submodule — override the build source instead:

```bash
make redeploy-backend BACKEND_SRC=../kube-state-graph
make redeploy-panel   PANEL_SRC=../kube-state-graph-panel
```

## Commands

```bash
make up          # submodules → cluster → images → load → dashboards → deps → install → wait
make down        # delete the kind cluster
make verify      # walk every hop of the pipeline and report which one is empty
make status      # pods across monitoring / shop / platform, plus PVCs
make graph       # raw /v1/graph JSON for the last 5 minutes
make lint        # gofmt -l + go vet on tools/, then helm lint on all four charts
make template    # render the umbrella chart without installing

make vendor-charts   # NEEDS NETWORK — refresh the vendored upstream subcharts
```

Iterating after `make up` — each rebuilds, re-loads into kind, and restarts:

```bash
make redeploy-backend      # kube-state-graph
make redeploy-panel        # panel bundle + Grafana restart
make redeploy-workloads    # demo-app / netapp-faker image, restarts every workload
```

Tailing: `make logs-backend`, `make logs-collector`, `make logs-faker`.

**There is no test suite here.** `tools/` has no `_test.go` files by design — the
binaries are demo fixtures and the real assertion is `make verify`. Treat a green
`make verify` as the completion criterion for any pipeline change; do not claim a
change works without running it.

Host requirements: `docker`, `kind`, `kubectl`, `helm`, `jq`, `curl`, `git`. Go and
Node are **not** needed — both builds run inside Docker.

Entry points: Grafana <http://localhost:3001> (anonymous Admin), Graph API
<http://localhost:18080/docs>, vmselect <http://localhost:18481/select/0/prometheus>.
Grafana is on 3001 so this can run beside the panel repo's own docker-compose demo.

## Where things live

| Path | Holds |
|---|---|
| `charts/ksg-demo/values.yaml` | the whole pipeline: VM, kube-state-metrics, OTel Collector, backend, faker, Grafana. Most changes land here |
| `charts/demo-workloads/values.yaml` | the estate the graph is a picture of — 7 workloads across `shop` / `platform` |
| `charts/kube-state-graph/`, `charts/netapp-faker/` | local charts for the two first-party deployments |
| `tools/cmd/demo-app` | one binary playing every workload role; role is entirely env config |
| `tools/cmd/netapp-faker` | the only fake component — discovers PVCs from vmselect, renders ONTAP series |
| `scripts/verify.sh` | one check per pipeline precondition, in data-flow order |
| `scripts/charts-deps.sh` | offline dependency materialisation, run by `make deps` |
| `kind/cluster.yaml` | 3 nodes (zone labels so `kube_node_labels` carries something), host port maps |

## Architecture notes that are not obvious from one file

**The graph is built from PromQL, never from the Kubernetes API.** A demo therefore
has to produce *metrics*, not objects. This is why the OTel Collector is
load-bearing and why every "fix" below is a metric-shape fix.

**One image, many roles.** All seven demo workloads run `ksg-demo/tools:local`.
What a workload *is* — gateway, mid-tier, storage leaf, load generator — is
decided by `UPSTREAMS`, `DB_ENDPOINTS`, `LISTEN_ADDR`, `CALL_INTERVAL` and whether
it mounts a claim. Add a workload by adding an entry to
`charts/demo-workloads/values.yaml`; no code change.

**`fullnameOverride` is pinned everywhere on purpose.** Half these components
address each other by URL in free-form config (the collector's remote-write
endpoint, the backend's `--prom-url`, the faker's two endpoints) and a URL cannot
be templated from inside a subchart's values. Renaming a service means hand-editing
every URL that names it.

**Images are side-loaded, never pulled.** Every local chart sets
`pullPolicy: Never` and `make load` runs `kind load docker-image`. A rebuilt image
is not live until it is both re-loaded and rolled out — that is what the
`redeploy-*` targets do.

**Dashboards are copied, not authored here.** `charts/ksg-demo/dashboards/*.json`
is overwritten wholesale by `make sync-dashboards` from
`kube-state-graph-panel/provisioning/dashboards/`. Edit them in the panel
submodule and re-sync; edits made here are lost on the next `make up`.

**Chart dependencies are vendored unpacked, and `make deps` is offline.** The
four upstream subcharts live under `charts/ksg-demo/charts/` as tracked
**directories**, not `.tgz` — Helm loads either, and a directory makes a version
bump a reviewable diff instead of an opaque blob. `make deps`
(`scripts/charts-deps.sh`) only packages the three first-party subcharts from
source and asserts each vendored directory carries the version `Chart.lock`
pins. It never runs `helm dependency update` — that would re-resolve every pin
against a repo index and break a disconnected bring-up.

The version assertion is not redundant: Helm does **not** re-check the version
of an unpacked subchart, so a hand-edited or half-updated directory would
install silently.

The three first-party archives are gitignored (covered by the blanket `*.tgz`)
on purpose: they are repackaged on every `make deps`, and a committed copy would
be a second, staler source of truth. To move an upstream pin, edit `Chart.yaml`
then run `make vendor-charts` **online** — it updates, unpacks, and lists what
to commit. The directories and `Chart.lock` must move as one, or `make deps`
reports the vendored set as stale.

## Invariants that fail silently

Nothing in this pipeline errors when a label is missing — the edge just disappears.
Before changing any of these, know what it removes:

- **`transform/external-labels` must reach every metric family**, kubelet and
  service-graph included. Every graph id is cluster-scoped and `?az=` / `?env=` are
  pushed to upstream PromQL as raw matchers; a family missing them matches nothing.
- **`translation_strategy: UnderscoreEscapingWithoutSuffixes`** stops
  `traces_service_graph_request_total` becoming `..._total_total`. The cost is the
  latency histogram losing its `_seconds`, which `transform/servicegraph-names`
  puts back. Change one and you must change the other.
- **`k8s.pod.uid` reaches spans via the downward API** (`OTEL_RESOURCE_ATTRIBUTES`
  in `charts/demo-workloads/templates/_container.tpl`) and is copied span-side by
  `transform/pod-uid`. Without it every call edge resolves to an anonymous
  `external` node instead of a pod.
- **`virtual_node_peer_attributes` lists only `peer.service`.** Adding an attribute
  the HTTP instrumentation also sets (`server.address`) would make every genuinely
  lost span pair masquerade as a resolvable peer.
- **kube-state-metrics allowlists are not defaults.** `metricLabelsAllowlist`
  (endpointslice service name, node zone/region) and `metricAnnotationsAllowList`
  (ArgoCD tracking-id on services and PVCs) are what produce `service-selects-pod`
  edges and the `application` grouping.
- **The storage join is exactly one equality**:
  `kube_persistentvolumeclaim_info.volumename == volume_labels.volume_name`.
  Nothing else. `netapp-faker` discovers claims from vmselect each tick and writes
  the PV name Kubernetes actually assigned.

## Deliberate negative cases — do not "fix" them

A demo where everything is green teaches nothing. These are intentional:

- `redis-data` sits on the **default** StorageClass, so it gets a PVC node and no
  storage chain. The backend logging one `netapp_volume_join_miss` per build for it
  is the demo working.
- `orders` answers **5% of requests with a 500** so its edges carry a non-zero
  `errorRate` — distinguishable from an edge with no measurement.
- `ontap-lab-02` reports `node_new_status 0`; degraded is a real reading, distinct
  from an absent series.
- `mongodb`'s Service is **headless** (`cluster_ip: None`), carrying no ipaddress.
- `catalog` reaches mongodb via a **connection string** (`dbEndpoints`) rather than
  an HTTP call, which is the only thing producing `pod-calls-service` plus its
  `service-selects-pod` fan-out. `orders` calls the same pods over HTTP, so both
  shapes appear.

`netapp-faker.emitVolumeStats: true` is a **kind-specific** override: kind's
local-path PVs are hostPath-backed and the kubelet exposes no
`kubelet_volume_stats_*` for them at all, so there is no real series to collide
with. On a real cluster this must be off.

## Debugging order

1. `make verify` — it asserts each precondition in the order data flows and names
   what breaks when it is empty. Start here, always.
2. An empty graph in the first minute after `make up` is expected: the backend
   builds over a window and nothing has been scraped yet. `make wait` blocks
   until a `pvc-to-netapp-aggr` edge exists — the longest chain, therefore the
   last thing to appear.
3. Cross-check with raw PromQL at the vmselect URL when the graph disagrees with
   what you think the metrics say.
