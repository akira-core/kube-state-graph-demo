## Why

The graph's user interface has moved out of Grafana. `kube-state-graph-panel` is
superseded by `kube-state-graph-frontend`, a standalone SPA that renders the same
topology with no Grafana, no datasource plugin and no dashboard JSON. This demo still
pins the panel, so it demonstrates a front end that is no longer the product.

Grafana was only ever the carrier. It existed here to load an unsigned panel plugin from
disk and to hand that panel a JSON transport; the ad-hoc PromQL it also offered is
already reachable at vmselect (`:18481`) and vmauth (`:18427`), which `scripts/verify.sh`
and the troubleshooting guide already query directly. With the panel gone, Grafana is a
chart dependency, a vendored subchart, a dashboard file, two datasources and two
`verify.sh` sections that carry no remaining demo claim.

Swapping the submodule alone does not produce a working demo. The SPA as it stands
fetches exactly one URL — `config.endpoints.graph`, verbatim — while `/v1/graph` requires
absolute `start` and `end` (`ParseValues` answers `missing_start` with a 400). A static
config would therefore pin the demo's front door to one frozen window that ages out of
retention, and would offer none of the six controls the dashboard exposed. The SPA's own
`NavBar` already has a time picker, but its resolved range reaches only the node-detail
dashboard link, never the graph fetch. Making the demo work again means teaching the SPA
to build its request, then rewiring this repository around it.

## What Changes

**In this repository**

- **BREAKING** The `kube-state-graph-panel` submodule is replaced by
  `kube-state-graph-frontend`, tracking `feat/pure-ui-frontend` over HTTPS.
- **BREAKING** Grafana is removed entirely: the chart dependency and its `Chart.lock`
  pin, the vendored `charts/ksg-demo/charts/grafana/` directory, the `grafana` values
  block with both datasources, `charts/ksg-demo/templates/dashboards-configmap.yaml`,
  and `charts/ksg-demo/dashboards/ksg-demo.json`.
- **BREAKING** The demo's front door on host port `3001` (NodePort `30300`) is now the
  SPA, not Grafana. The kind port mapping is unchanged; what answers on it is not.
- A new first-party chart `charts/kube-state-graph-frontend/` deploys the SPA: a
  Deployment, a NodePort Service pinned to `30300`, a ConfigMap holding `config.json`,
  and a Secret holding a replacement `nginx.conf`. The replacement conf is the
  documented override point in the frontend image and carries two same-origin proxies —
  `/api/` to `kube-state-graph:8080`, and a label-values path to `vm-auth:8427` with the
  demo's basic-auth credential injected server-side, so the browser never holds it.
- `docker/panel.Dockerfile` is deleted; the frontend image is built from the submodule's
  own `Dockerfile`. `PANEL_SRC` / `PANEL_IMAGE` / `make redeploy-panel` become
  `FRONTEND_SRC` / `FRONTEND_IMAGE` / `make redeploy-frontend`.
- `scripts/verify.sh` sections 10 and 11 are rewritten: instead of walking dashboard JSON
  and Grafana's datasource API, they assert the SPA's served `config.json`, that its
  configured graph endpoint answers through the SPA's own origin, and that the
  label-values proxy returns the **raw** cluster name and not the composed identity.
- `scripts/wait-ready.sh` additionally gates on the SPA answering `/healthz`.
- `scripts/charts-deps.sh`, `kind/cluster.yaml`, `Makefile`, `README.md` and `CLAUDE.md`
  are updated to describe the SPA front door instead of Grafana.

**Upstream, in `kube-state-graph-frontend` (prerequisite, its own commit and PR)**

- The graph fetch is built from the existing time-range selection instead of using
  `config.endpoints.graph` verbatim, so the `NavBar` picker drives the request and
  `start` / `end` are always present and always current.
- A filter control bar supplies `cluster`, `az`, `env`, `namespace`, `edge_type` and
  `prune` as query parameters on that same request, restoring the six dashboard
  variables the panel version had.
- `config.endpoints` gains a label-values endpoint whose options feed those four identity
  controls, read from the Prometheus-shaped
  `/api/v1/label/<name>/values?match[]=kube_pod_info` contract.

No change is needed in `kube-state-graph`: its request contract already accepts
everything the SPA must send.

## Capabilities

### New Capabilities

- `frontend-provisioning`: how the demo builds, deploys and configures the standalone SPA
  as its front door — image source, runtime configuration ownership, the same-origin
  proxies that reach the backend and the metric store, the entry point it answers on, and
  the readiness gate that makes `make up` mean something.
- `frontend-graph-controls`: the contract the front door owes the backend — every request
  carries a current window, every shipped control changes what the backend returns, and
  the identity filters offer values the backend can act on.

### Modified Capabilities

- `dashboard-provisioning`: retired in full. Every requirement in it is about a Grafana
  dashboard the demo provisions — its source of truth, the endpoints and parameters it
  may send, where its variables read from, and its projection control. With Grafana
  removed there is no provisioned dashboard, so the requirements are removed rather than
  reworded; the claims worth keeping are restated against the SPA in
  `frontend-graph-controls`.

## Impact

- **Submodules**: `kube-state-graph-panel` removed, `kube-state-graph-frontend` added.
  `.gitmodules`, `.git/modules`, and the CLAUDE.md submodule table all move. The upstream
  frontend PR must merge first — a submodule pointer here must name a commit that exists
  upstream.
- **Charts**: `charts/ksg-demo/Chart.yaml`, `Chart.lock` and `charts/ksg-demo/charts/`
  lose Grafana. Refreshing `Chart.lock` needs network (`make vendor-charts`), the same
  path the repository already documents for moving a pin.
- **Credential surface**: `global.ksgUpstreamAuth` gains a fifth consumer. It is injected
  into the SPA's nginx configuration through a Secret, so it does not reach the browser
  and does not appear in a ConfigMap.
- **Scripts**: `verify.sh` (sections 10–11), `wait-ready.sh`, `charts-deps.sh`.
- **Entry points**: `make urls`, `README.md` and `CLAUDE.md` all name Grafana as the
  front door today.
- **Not affected**: the metric pipeline, both stores, the routing table, the workload
  estate, `tools/`, and every invariant in CLAUDE.md's "Invariants that fail silently"
  section except the dashboard one.
