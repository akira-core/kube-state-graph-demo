## Context

See `proposal.md` — Why. The constraints that shape the approach, all verified against
the pinned sources rather than assumed:

- **The backend requires an absolute window.** `pkg/kubegraph/parse.go` rejects a request
  with no `start` (`missing_start`) or no `end` (`missing_end`), and accepts only RFC 3339
  or Unix seconds — there is no relative form and no default.
- **The SPA fetches one URL verbatim.** `useGraphLoader` calls
  `fetchJson(config.endpoints.graph)` with nothing appended. Its `NavBar` already renders
  a 1h/6h/24h/7d + absolute time picker, but `useViewTimeRange`'s resolved range reaches
  only the node-detail dashboard link — never the graph request.
- **The wire contract already matches.** `src/shared/types/wire.ts` is the backend's
  `/v1/graph` cytoscape body field for field, snake_case included. No translation layer is
  needed, and none should be introduced.
- **Grafana is a carrier, not a feature.** Its whole job here was
  `extraInitContainers` copying `/plugin` into `/var/lib/grafana/plugins`, plus an
  Infinity datasource as JSON transport and two Prometheus datasources. The demo's
  documented debugging path already queries vmselect and vmauth directly.
- **The pod inventory is behind basic auth.** `kube_pod_info` lives only in the
  single-node store, reachable through vmauth, and `?cluster=` takes the raw label value
  while the graph response's `clusters[]` is the composed `<az>-<env>-<cluster>` identity.
  Feeding an identity back as a filter returns an empty 200 — the bug PR #5 and #6 fixed.
- **Repository conventions that constrain the shape:** images are side-loaded with
  `pullPolicy: Never`; `fullnameOverride` is pinned because components address each other
  by URL in free-form config; `make deps` is offline and asserts vendored subchart
  versions against `Chart.lock`.

## Goals / Non-Goals

**Goals:**

- The demo's front door draws a live graph from the running backend, with a window that
  keeps moving and six controls that reach the backend.
- Nothing the browser receives carries the metric store's credential.
- The demo repository holds no copy of frontend application logic — its job stays wiring.
- `make verify` remains the completion criterion, and covers the new front door.

**Non-Goals:**

- Preserving Grafana for ad-hoc PromQL. vmselect and vmauth answer that already, and
  keeping a whole chart, two datasources and a vendored subchart for a URL bar is not
  worth the surface.
- Changing `kube-state-graph`. Its request contract accepts everything needed.
- Feature parity with the panel's rendering. What is being asserted is the request
  contract and the pipeline behind it, not pixel behaviour.
- Building a general-purpose metrics proxy. The label-values path exists to populate four
  controls and is scoped to exactly that.

## Decisions

### D1 — The window is built by the frontend, not injected by a proxy

The frontend wires `useViewTimeRange`'s resolved range into the graph request:
`endpoints.graph` becomes a base URL and the loader appends `start` / `end` (Unix
seconds) plus the filter parameters.

*Alternative — a Go window-injecting reverse proxy in `tools/`.* It would keep every
change inside this repository and match the "first-party code only in `tools/`"
convention. Rejected because it makes the SPA's own time picker decorative: the control
is visible, movable, and cannot change the graph — exactly the failure mode
`frontend-graph-controls` forbids, reproduced deliberately.

*Alternative — a default window in the backend.* Smallest diff, but it changes a
published API contract for every embedder in order to accommodate one demo front end, and
`start`/`end` being required is what makes a stale window impossible today.

### D2 — Filters are sent to the backend, not applied client-side

The SPA already has an `element-filter` feature doing client-side visibility. It is not
the mechanism here: the demo's claim is that `cluster` / `az` / `env` / `namespace` are
pushed into upstream PromQL as raw label matchers, and a client-side filter over a
full-inventory payload demonstrates nothing about that. Client-side filtering stays what
it is — a visual refinement on top of whatever the backend returned.

### D3 — Identity options come from a Prometheus label-values endpoint

`config.endpoints` gains a label-values base URL. The frontend builds
`<base>/api/v1/label/<name>/values?match[]=kube_pod_info` for `cluster`, `az`, `env` and
`namespace` — the standard Prometheus HTTP API shape, answering
`{"status":"success","data":[…]}`. The `kube_pod_info` selector is fixed in the frontend;
it is the family that defines the Kubernetes pod inventory, and making it configurable
would only create a way to point the controls at something the backend cannot filter on.

*Alternative — derive options from the graph payload.* No new endpoint, but `cluster`
would offer `local-a-demo-ksg-demo` (an empty-200 filter value), and `az` / `env` are not
in the payload at all. This is the regression PR #5 fixed; re-introducing it is not on
the table.

*Alternative — plain text inputs.* Smallest frontend change, but a typo and a broken
pipeline both render as an empty graph, which is the one confusion this demo exists to
prevent.

### D3b — Edge-type options come from the backend's own catalogue

Resolved during implementation; the specs left the source of this one control open.
`config.endpoints` also gains `edgeTypes`, pointed at `/v1/edge-types`. Upstream serves
that catalogue from the **same registry** that validates `?edge_type=`
(`pkg/graph/registry.go` derives `validEdgeTypes` from `EdgeTypes`), so an option read
from it is always one the backend accepts.

*Alternative — a list held in the front end.* Rejected on a concrete case: the frontend's
own `EdgeType` union already carries `switch-to-switch` and `node-to-switch`, which the
pinned backend does **not** register as filter values. Offering either produces a 400
`invalid_scope`, not a narrowed graph — a control that breaks the page rather than one
that merely does nothing.

*Alternative — derive the options from the loaded graph payload.* Guaranteed-accepted
values, but the list shrinks to whatever the current selection returned, so a viewer who
picks one edge type cannot switch to another without clearing first. Fixing that needs a
"remember the last unfiltered response" state machine for no gain over reading the
catalogue.

The endpoint is optional. Absent, the edge-type control is simply not offered — the same
degradation rule as the label-values source.

### D4 — The demo replaces the image's `nginx.conf` rather than changing the image

The frontend image documents `/etc/nginx/nginx.conf` as an override point. This demo's
chart renders a complete replacement conf into a **Secret** (not a ConfigMap — it embeds
the basic-auth header) and mounts it over that path. The replacement is derived from the
image's shipped conf, keeping its `/healthz`, `/config.json`, `/assets/` and SPA-fallback
blocks verbatim, and defines two proxies of its own:

```
location /api/            -> http://kube-state-graph:8080/
location /metrics-api/api/v1/label/  -> http://vm-auth:8427/api/v1/label/
                             + proxy_set_header Authorization "Basic <rendered>"
```

The replacement deliberately drops `include /tmp/api_proxy.conf;` and the deployment
leaves `KSG_API_PROXY_TARGET` unset. The image's entrypoint still writes that file; it is
simply not included. Including it *and* defining `location /api/` would be a duplicate
location and nginx would refuse to start.

The metrics proxy is scoped to the `/api/v1/label/` prefix, not the whole store. The
credential is a laptop demo secret, but a same-origin path that proxies arbitrary PromQL
with credentials attached is a worse default than one that proxies four label lookups.

*Alternative — teach the frontend image a second proxy target env var.* Cleaner for a
real deployment, but it puts demo-specific wiring in the product image and would need the
credential as an environment variable there anyway.

### D5 — Path prefixes

`/api/` stays the backend, matching the frontend repository's own documented convention
and its `deploy/` sample. Label values get `/metrics-api/`, a distinct prefix so the two
upstreams can never be confused in a `verify.sh` failure or a browser network tab.

### D6 — The front door keeps host port 3001 / NodePort 30300

`kind/cluster.yaml` is unchanged apart from its comment. The published address in the
README, `make urls` and CLAUDE.md does not move; what answers on it does. Grafana is gone,
so there is no conflict, and a moved address would invalidate every document and bookmark
for no gain.

### D7 — The image is built from the submodule's own Dockerfile

`docker/panel.Dockerfile` existed because a panel plugin is not a server: it had to be
hand-written here to turn a build into a file carrier. The frontend ships a complete
multi-stage Dockerfile producing an nginx server, so this repository builds
`-f $(FRONTEND_SRC)/Dockerfile $(FRONTEND_SRC)` and deletes its own. `docker/` keeps
`backend.Dockerfile` and `tools.Dockerfile`, which have no upstream equivalent.

### D8 — A first-party chart, wired like the others

`charts/kube-state-graph-frontend/` follows `charts/kube-state-graph/`: pinned
`fullnameOverride`, `pullPolicy: Never`, a `file://../kube-state-graph-frontend`
dependency in the umbrella `Chart.yaml`, and an entry in `scripts/charts-deps.sh`'s
`local_charts` so `make deps` packages it. `config.json` is a ConfigMap mounted as a
**directory** at `/srv/config` — the frontend repository's `deploy/README.md` is explicit
that `subPath` breaks ConfigMap update propagation.

### D9 — Removing Grafana means refreshing `Chart.lock` online

Dropping a dependency changes the lock's digest, and `make deps` is offline by design and
will not regenerate it. The move is the one the repository already documents for changing
a pin: edit `Chart.yaml`, run `make vendor-charts` with network, commit the regenerated
`Chart.lock` together with the deleted `charts/ksg-demo/charts/grafana/` directory. They
must move as one commit or `make deps` reports the vendored set as stale.

### D10 — `verify.sh` keeps its numbering; sections 10 and 11 change subject

Section 10 becomes the front door's served configuration and the graph endpoint that
configuration names, requested **through the frontend's own origin** rather than against
the backend directly — proxying is the thing under test. Section 11 becomes the
label-values path, asserting it returns the raw `ksg-demo` and that the composed identity
is absent from the list. The section headers keep naming their store, as every other
section does.

### D11 — Two repositories, one order

The upstream frontend change lands first, as its own PR in
`kube-state-graph-frontend`. Only then does this repository pin a submodule commit,
because a pointer here must name a commit that exists upstream. Development before that
merge uses the existing override convention:

```bash
make redeploy-frontend FRONTEND_SRC=../kube-state-graph-frontend
```

## Risks / Trade-offs

- **The upstream frontend PR is a hard prerequisite** → Every task here that pins the
  submodule is sequenced after it. Until then `FRONTEND_SRC` builds from a working copy,
  which is the same escape hatch the backend already has, so this repository's work is not
  blocked — only its final commit is.
- **The replacement `nginx.conf` forks from the image's** → A future upstream change to
  caching, the SPA fallback or `/healthz` would not reach the demo. Mitigated by deriving
  the file from the shipped conf, carrying a comment naming that origin, and asserting
  `/healthz` and `/config.json` in `verify.sh` so a drift that breaks either is caught.
- **A duplicate `location /api/` makes nginx refuse to start** → The pod would crash-loop
  rather than degrade, which is the good failure. Called out in D4 and in the chart's own
  comment so nobody re-adds `KSG_API_PROXY_TARGET` alongside the replacement conf.
- **Ad-hoc PromQL loses a UI** → vmselect (`:18481`) and vmauth (`:18427`) keep their own
  endpoints and every `verify.sh` section already names which store it queries. README and
  CLAUDE.md must state this explicitly, or the first person to debug the pipeline will look
  for Grafana.
- **Credentials in a rendered nginx config** → It is a Secret, not a ConfigMap, and the
  value is the demo's existing throwaway credential sourced from `global.ksgUpstreamAuth`
  rather than a new literal. No second copy is introduced.
- **`make vendor-charts` needs network** → Unavoidable for a dependency change, and
  already the documented path. The commit must carry `Chart.yaml`, `Chart.lock` and the
  deleted vendored directory together.
- **The demo's front door now runs its own npm build** → Comparable to the panel build it
  replaces, so `make up` wall-clock is roughly unchanged.

## Migration Plan

1. **Upstream** (`kube-state-graph-frontend`, `feat/pure-ui-frontend`): wire the time
   range into the graph request, add the filter control bar, add the label-values and
   edge-type endpoints to the runtime config schema. Push it; note the commit. The demo
   tracks that BRANCH, as it tracked the panel's feature branch before it, so the pointer
   here moves to the branch head rather than waiting on a merge to `main`.
2. **Here, independent of step 1**: add `charts/kube-state-graph-frontend/`, wire it into
   the umbrella chart, add the Makefile targets, remove Grafana, rewrite the scripts and
   the docs. Develop against `FRONTEND_SRC=../kube-state-graph-frontend`.
3. **Submodule swap**: `git submodule deinit` + remove `kube-state-graph-panel`, add
   `kube-state-graph-frontend` over HTTPS on the tracked branch, pinned to step 1's commit.
4. **`make vendor-charts`** online, commit the regenerated `Chart.lock` and the removed
   vendored Grafana directory.
5. **`make down && make up && make verify`** from a clean checkout. A green walk is the
   completion criterion; there is no test suite here.

**Rollback**: this repository's change is one branch. Reverting it restores the panel
submodule, the Grafana dependency and the dashboard, since nothing outside it is mutated —
the backend is untouched and the frontend repository's change is additive and independent.

## Open Questions

- Whether the provisioned `refreshIntervalSeconds` should stay `0` (manual reload, the
  frontend's default) or auto-refresh on an interval so an idle demo keeps moving. It
  changes one value in a tracked ConfigMap, no spec and no task, and is best answered after
  seeing the demo run.
