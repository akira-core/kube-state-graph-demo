# kube-state-graph-demo

A complete, self-drawing demo of [`kube-state-graph`](https://github.com/akira-core/kube-state-graph)
and [`kube-state-graph-frontend`](https://github.com/akira-core/kube-state-graph-frontend)
on a local **kind** cluster.

One `make up` builds both projects from source, stands up the whole metrics
pipeline behind them, deploys a synthetic microservice estate that calls itself,
and hands you a standalone web UI drawing that estate as an interactive graph.
There is no Grafana: the front end is its own single-page application, served by
nginx, talking to the backend through its own origin.

![The front door: the demo estate as a live graph](docs/ksg-demo.png)

```bash
make up          # ~5 minutes on a cold laptop
open http://localhost:3001      # the front door: Graph and Sankey views
```

Then:

```bash
make verify      # walk every hop of the pipeline and say which one is empty
make status      # pods across all three demo namespaces
make graph       # the raw /v1/graph JSON
make down        # delete the cluster
```

## What is real and what is not

kube-state-graph does not read the Kubernetes API. It builds the entire graph
from PromQL over a `[start, end]` window, which means a demo has to produce
*metrics*, not objects. Almost all of them here are produced by real components
doing real work:

| Real | Faked |
|---|---|
| Pods, Services, EndpointSlices, PVCs — actual Kubernetes objects on a 3-node kind cluster | The **NetApp ONTAP array**: aggregates, controllers, FlexVol topology and QoS I/O |
| kube-state-metrics, scraped by vmagent for the topology series the graph reads | |
| Real kubelet volume stats for claims on `netapp-nas` (CSI NFS `NodeGetVolumeStats`) | |
| Real HTTP calls between workloads, traced with OpenTelemetry | |
| The service-graph metrics, derived from those traces by the collector | |

There is exactly one component whose data is invented — `netapp-faker` — because
a laptop cannot run an ONTAP array. Even that one **discovers rather than
fixtures**: every tick it asks the store holding the kube-state-metrics series
which claims exist on the demo StorageClass and renders a storage chain behind the `pvc-<uuid>` PV names
Kubernetes actually assigned. Create a PVC and its aggregate, controller and I/O
appear within one tick.

## The pipeline

```
 shop / platform namespaces          monitoring namespace
┌──────────────────────────┐   ┌───────────────────────────────────────────────┐
│ loadgen                  │   │                                               │
│   └→ edge-gateway ─┬→ catalog ──→ redis      OTLP traces                     │
│                    └→ orders ──┬→ mongodb        │                           │
│                                └→ nats           ▼                           │
│                                          ┌───────────────┐                   │
│  kube-state-metrics ──┐                  │ OTel Collector│                   │
│  kubelet          ──┐ │                  │  servicegraph │                   │
└─────────────────────┼─┼──┐               │  connector    │                   │
                      │ │  │               │  + cluster/az │  netapp-faker     │
                 scrape │  │               │    /env stamp │       │ import    │
                      ▼ ▼  │               └───────┬───────┘       │           │
              ┌───────────┐│                       │               │           │
              │  vmagent  ││                       ▼               ▼           │
              │ + stamp   ││          ┌──────────────────────────────────┐     │
              └─────┬─────┘│          │   store 1: VictoriaMetrics       │     │
                    ▼      │          │   cluster — vminsert → vmstorage │     │
        ┌──────────────────┴───┐      │             → vmselect           │     │
        │ store 2: vmsingle    │      │   harvest, servicegraph          │     │
        │ ksm, kubelet         │      └──────────────┬───────────────────┘     │
        └───────┬──────────────┘                     │                         │
                ▼ (basic auth)                       │                         │
        ┌───────────────┐                            │                         │
        │    vmauth     │◀── discovery ── netapp-faker                          │
        └───────┬───────┘                            │                         │
                │           PromQL, routed by family │                         │
                └──────────────┬─────────────────────┘                         │
                      ┌────────▼─────────┐                                     │
                      │ kube-state-graph │  backends.yaml routing table        │
                      └────────┬─────────┘                                     │
                               │ /v1/graph (Cytoscape JSON)                    │
                      ┌────────▼─────────┐                                     │
                      │ kube-state-graph-frontend (nginx + SPA)                │
                      │   /api/          ─────────▶ kube-state-graph             │
                      │   /metrics-api/  ─────────▶ vmauth (credential attached  │
                      │                              in-cluster, never in the    │
                      │                              browser)                    │
                      └────────────────────────────────────────────────────────┘
```

### Two stores, one graph

The metrics live in **two** Prometheus-compatible installations, and
kube-state-graph assembles one graph from both. The split is by producer:

| Store | Query families | Written by | Read path |
|---|---|---|---|
| VictoriaMetrics **cluster** | `harvest`, `servicegraph` | netapp-faker (import), OTel Collector (remote-write) | vmselect, unauthenticated |
| VictoriaMetrics **single** | `ksm`, `kubelet` | vmagent | vmauth, basic auth |

The `probe` family (`up{}`) is served by both, so `/readyz` asks both stores
rather than calling the estate healthy on the strength of one.

This is not decoration. It puts the two halves of the storage join in different
stores — `kube_persistentvolumeclaim_info` in one, `volume_labels` in the
other — so **no PromQL can join them**. A `pvc-to-netapp-aggr` edge in the
rendered graph is therefore proof that the backend's fan-out and merge both
work, and `make wait` already gates on exactly that edge.

The single-node store also serves the Prometheus API under `/prometheus` where
the cluster build serves it under `/select/<accountID>/prometheus`, so the two
differ in shape and not only in name.

The routing table lives in `charts/ksg-demo/values.yaml` under
`kube-state-graph.backends`, is rendered into a ConfigMap, and is re-read every
30s without a restart. Removing it is a complete rollback to the single-upstream
deployment: `--prom-url` still points at the cluster store, and the backend
falls back to one implicit backend serving every family.

Credentials are the one thing the routing file never carries. It names the
environment *variables* (`usernameEnv` / `passwordEnv`); a literal password in
the file is rejected, and a variable named there but unset is a load failure
rather than a quiet fallback to no credentials.

### Why the OpenTelemetry Collector is load-bearing

It does two jobs no other component can:

1. **Turns traces into service-graph metrics.** Its `servicegraph` connector
   pairs each CLIENT span with the SERVER span it caused and emits
   `traces_service_graph_request_*` carrying `client_k8s_pod_uid` /
   `server_k8s_pod_uid` — the only thing that lets the backend resolve a call
   edge to a *pod* rather than to an anonymous `external` node. The pod UID
   reaches the span via the downward API (`OTEL_RESOURCE_ATTRIBUTES`).
2. **Stamps `cluster`, `az` and `env` on them.** No exporter here emits these,
   yet every graph id is cluster-scoped as the composed identity
   `<az>-<env>-<cluster>` (the demo renders `local-a-demo-ksg-demo`) and the
   `?az=` / `?env=` / `?cluster=` request filters are pushed to upstream PromQL
   as raw label matchers. A family missing them does not error — it silently
   matches nothing, or composes a second identity if only the pair disagrees.

It scrapes **nothing**. The kube-state-metrics and kubelet jobs are vmagent's,
because the series they produce belong to the other store. vmagent stamps the
same three labels on what it collects, and both read them from one place —
`global.ksgExternalLabels` in `charts/ksg-demo/values.yaml` — because a value
that differed between the two would silently split the graph into two cluster
identities (or drop half of it out of any filtered request).

### Every edge type the backend can produce

The demo is arranged so that all six appear:

| Edge | Produced by |
|---|---|
| `pod-to-node` | every scheduled pod |
| `pod-mounts-pvc` | `mongodb`, `nats`, `redis` |
| `pod-calls-pod` | the HTTP call chain, with RED metrics |
| `pod-calls-service` | `catalog`'s connection-string peer (see below) |
| `service-selects-pod` | the fan-out from that Service to `mongodb-0/1` |
| `pvc-to-netapp-aggr` | the faked ONTAP estate |

`pod-calls-service` needs explaining, because it is not what you would guess.
Service nodes are materialised **on demand**, only for a Service some endpoint
actually named as a `://` connection string. So `catalog` emits a client span
with no server span and `peer.service =
mongodb://mongodb.shop.svc.cluster.local:27017`; the collector turns an
unmatched client span into a *virtual node* labelled with that attribute, and
the backend parses the host, classifies it as Kubernetes `.svc` DNS, and
resolves it to the real `mongodb` Service. `orders` still calls the mongodb
*pods* over HTTP, so the demo shows both shapes reaching the same backend.

### Deliberate negative cases

A demo where everything is green teaches nothing. These are on purpose:

- **`redis-data` is on the default StorageClass**, not `netapp-nas`. It gets a
  PVC node and no storage chain — which is how an operator tells "never meant to
  have a NetApp backend" apart from "should have joined and did not". The
  backend logs one `netapp_volume_join_miss` for it every build; that warning is
  the demo working, not failing.
- **`orders` answers 5% of requests with a 500**, so its edges carry a non-zero
  `errorRate`. An edge with `errorRate: 0` and an edge with no measurement at
  all must look different in the UI.
- **`ontap-lab-02` reports `node_new_status 0`.** Degraded is a real reading,
  distinct from the series being absent.
- **`mongodb`'s Service is headless**, so its `cluster_ip` is `None` and it
  carries no ipaddress — again distinct from an unknown one.
- **Shared NFS export capacity.** `csi-driver-nfs` reports `statfs` of the
  in-cluster Ganesha export, so every claim on `netapp-nas` shows that
  export's size as `capacity_bytes`, not the claim's request. The demo
  proves the kubelet series exist and join; numeric per-claim fidelity is
  not what it demonstrates.

## Layout

```
charts/
  ksg-demo/          umbrella release: pins every upstream chart + the local ones
  kube-state-graph/  the API server
  kube-state-graph-frontend/  the front door: SPA config + nginx proxies
  netapp-faker/      the one fake component
  demo-workloads/    namespaces, StorageClass, workloads, Services, claims
  nfs-server/        in-cluster Ganesha export for csi-driver-nfs
docker/              two Dockerfiles: backend, demo tools. The front end is built
                     from the submodule's own Dockerfile — it ships a complete one
kind/cluster.yaml    3 nodes, zone labels, host port mappings
tools/               Go: the demo workload and the ONTAP faker
scripts/             wait-ready, verify, charts-deps, vendor-charts
kube-state-graph/           ── git submodule
kube-state-graph-frontend/  ── git submodule
```

### Chart dependencies are vendored, unpacked

The upstream charts are committed under `charts/ksg-demo/charts/` as plain
directories, not fetched at bring-up and not stored as `.tgz`:

```
charts/ksg-demo/charts/
  kube-state-metrics/        8.4.0      ── vendored, tracked
  opentelemetry-collector/   0.170.0    ── vendored, tracked
  victoria-metrics-cluster/  0.49.0     ── vendored, tracked   store 1
  victoria-metrics-single/   0.45.0     ── vendored, tracked   store 2
  victoria-metrics-agent/    0.46.0     ── vendored, tracked   scrapes into store 2
  victoria-metrics-auth/     0.40.0     ── vendored, tracked   store 2's read path
  csi-driver-nfs/            4.13.4     ── vendored, tracked
  *.tgz                                 ── first-party charts, rebuilt by make deps
```

`helm dependency update` re-resolves every pin against its repo index, which
makes a disconnected `make up` fail before a single pod is scheduled — and it
also means the demo's meaning could shift under a moving index. So `make deps`
does not touch the network: it packages the first-party subcharts from
source and asserts the vendored ones are present *at the version
`Chart.lock` pins*. Helm does not re-check that for an unpacked subchart, so a
hand-edited or half-updated directory would otherwise install silently.

Unpacked rather than archived because a directory is reviewable: a version bump
arrives as a readable diff instead of an opaque binary blob, which for a repo
whose whole substance is wiring is the difference between a reviewable upgrade
and a leap of faith.

The first-party subcharts are deliberately *not* committed. They are the only
dependencies whose content changes between commits, and a checked-in copy would
be a second, staler source of truth — edit `demo-workloads/values.yaml`, forget
to repackage, and the install would quietly use the old one.

To move a pin, edit `charts/ksg-demo/Chart.yaml` and then, **online**:

```bash
make vendor-charts    # helm dependency update, unpack, then list what to commit
```

Commit the subchart directories together with `Chart.lock`; the two must move
as one or `make deps` reports the vendored set as stale.

Vendoring the charts is not by itself enough to bring the demo up on a
disconnected laptop — `kind create cluster`, the three `docker build`s (base
images, `go mod download`, `npm ci`) and the upstream container images all
still reach out. What it does buy is that
none of that happens at *Helm* time, and that a warm Docker cache is the only
other thing standing between a cold checkout and an offline bring-up.

Both first-party projects are **git submodules**, and every image is built from
them locally and side-loaded into kind with `kind load docker-image` — no
registry involved. To demo an unpushed local change, point the build at your own
working copy:

```bash
make redeploy-backend  BACKEND_SRC=../kube-state-graph
make redeploy-frontend FRONTEND_SRC=../kube-state-graph-frontend
make redeploy-workloads
```

Service names inside the cluster are pinned with `fullnameOverride` rather than
derived from the release name, because half of these components address each
other by URL in free-form config (the collector's remote-write endpoint, the
backend's `--prom-url`, the faker's two endpoints) and a URL cannot be templated
from inside a subchart's values.

## Entry points

| | URL | Notes |
|---|---|---|
| Front door | <http://localhost:3001> | the SPA: Graph and Sankey views, with the filter bar |
| Graph API | <http://localhost:18080/docs> | Scalar UI over the OpenAPI spec |
| VM cluster store | <http://localhost:18481/select/0/prometheus> | vmselect — Harvest and service-graph series, in raw PromQL |
| VM single store | <http://localhost:18427> | vmauth — kube-state-metrics and kubelet series. Needs `curl -u ksg:ksg-demo-not-a-real-secret` |

The front door is on **3001**, not the usual 3000, so this can run beside the
frontend repo's own `npm run dev`.

**There is no Grafana.** Ad-hoc PromQL goes straight to the stores — and you have
to ask the right one:

```bash
# cluster store: Harvest, service-graph
curl -sG http://localhost:18481/select/0/prometheus/api/v1/query --data-urlencode 'query=volume_labels'

# single-node store: kube-state-metrics, kubelet. Basic auth.
curl -sG -u ksg:ksg-demo-not-a-real-secret http://localhost:18427/api/v1/query \
  --data-urlencode 'query=kube_pod_info'
```

A query sent to the wrong store returns an empty result that looks exactly like a
broken pipeline, which is why every `verify.sh` section header names its store.

The front door's runtime configuration is authored in this repository, at
`charts/kube-state-graph-frontend/values.yaml`, and mounted as
`/srv/config/config.json`. It sets `demoMode: false` — `true` would render the
frontend's own bundled showcase fixture, a convincing graph that proves nothing
about the pipeline behind it.

Everything the browser fetches it fetches from **its own origin**, and nginx
forwards it in-cluster:

| Browser asks | Reaches | Why not direct |
|---|---|---|
| `/api/v1/graph`, `/api/v1/edge-types` | `kube-state-graph:8080` | the backend would otherwise need a CORS policy naming this origin |
| `/metrics-api/api/v1/label/<name>/values` | `vm-auth:8427`, with the basic-auth header attached in-cluster | the credential must never reach a browser |

The filter bar sends what it collects straight to the backend. `cluster`, `az`,
`env` and `namespace` options are `kube_pod_info` label values from the
**single-node** store — that is the raw name, which is what `?cluster=` accepts.
`clusters[]` on the graph response is the composed identity `<az>-<env>-<cluster>`
(`local-a-demo-ksg-demo` here) and is **not** a valid `?cluster=` value.
`edge_type` options come from `/v1/edge-types`, which is the same registry the
backend validates that parameter against. `Projection` is the backend's
`?prune=`: **Traffic graph** (the default) draws only workload sitting on a
connectivity edge, **Full inventory** draws every loaded pod plus the
infrastructure nothing references — which is what `make verify` asserts against,
so the two agree only in that position.

The time picker in the nav bar is the request window: the backend requires an
absolute `start` and `end` on every call, and the front end resolves the
selection at request time so a reload never re-asks for a stale window.

## Troubleshooting

Start with `make verify`. Nearly every failure mode in this pipeline is silent —
a missing label does not error, it just removes edges — so the script asserts
each precondition in the order the data flows and names what breaks when it is
missing:

```
== 7. the split is real, and the join spans it ==
   ok   volume_name joins a real PV across stores      3 PV names in both stores
   ok   cluster store holds no kube_pod_info           0 series
   ok   single store holds no volume_labels            0 series
   ok   vmauth rejects an unauthenticated read         HTTP 401

== 8. upstream backend routing ==
   ok   routing table has both backends                kube_state_graph_upstream_backends = 2
   ok   backend cluster-store failures during one build 0 new (15 lifetime)
   ok   backend single-store failures during one build 0 new (38 lifetime)
   ok   /readyz — every backend answered               HTTP 200
```

Because the demo now spans two stores, every check names the one it asks: a
query sent to the wrong store returns an empty result that looks exactly like a
broken pipeline. The per-backend failure counters are read as a **delta across
one graph build** rather than as absolutes — they are cumulative since process
start, and a cold bring-up reliably puts tens of connection-refused errors in
them because the server is ready before either store is.

The graph is also empty for a mundane reason for the first minute or so: the
backend builds over the requested window, and nothing has been scraped yet.
`make wait` (part of `make up`) blocks until the front door answers `/healthz`
and until a `pvc-to-netapp-aggr` edge exists — the longest chain in the demo,
and therefore the last thing to appear.

| Symptom | Look at |
|---|---|
| Front door loads but the graph is blank with an error | the `/api/` proxy is not reaching the backend — `kubectl -n monitoring logs deployment/kube-state-graph-frontend` |
| Front door shows a graph with no live data behind it | `demoMode` is `true` in the served `/config.json`; the SPA is drawing its own bundled fixture |
| Graph has pods but no call edges | `make logs-collector`; check `client_k8s_pod_uid` in `make verify` |
| Call edges end in `external` nodes | the pod UID is not reaching the spans — check `OTEL_RESOURCE_ATTRIBUTES` on a workload |
| No pods or nodes at all | `kubectl logs deployment/vm-agent` — nothing is scraping into the single-node store |
| No storage half at all | `make logs-faker`; the join is `kube_persistentvolumeclaim_info.volumename == volume_labels.volume_name` and nothing else, and its two halves are in different stores |
| Edges have no `p90ServerMs` | the collector's `transform/servicegraph-names` — with metric suffixes off, the histogram loses its `_seconds` and must have it put back |
| `/readyz` is 503 naming a backend | that store is down or unreachable; the body names the backend, never its URL |
| Everything filtered by `?az=` is empty | vmagent's `external_labels` and the collector's `transform/external-labels` disagree — both must come from `global.ksgExternalLabels` |
| Graph ids / cluster compound read `local-a-demo-ksg-demo` | expected: that is the composed identity `<az>-<env>-<cluster>` |
| `?cluster=local-a-demo-ksg-demo` is empty | expected: `?cluster=` takes the raw name `ksg-demo`; pin with `?az=local-a&env=demo&cluster=ksg-demo` |
| Cluster / AZ / Env / Namespace controls are empty | the `/metrics-api/` proxy is not reaching vmauth, or the `Authorization` header it attaches is wrong — check `global.ksgUpstreamAuth` and the front end's nginx Secret |
| Edge-type control is empty | `/api/v1/edge-types` is not answering through the front door |
| Backend logs "upstream backends did not answer" right after `make up` | expected: the server is ready before either store is, and it retries |

## Requirements

`docker`, `kind`, `kubectl`, `helm` (v3 or v4), `jq`, `curl`, and `git`. Go and
Node are **not** required on the host — both builds run inside Docker.
