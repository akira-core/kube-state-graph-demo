## 1. Upstream frontend (repo `kube-state-graph-frontend`, branch `feat/pure-ui-frontend`)

These land as their own commits and PR in that repository — see design.md D11. Work in
this repository can proceed in parallel using `FRONTEND_SRC=../kube-state-graph-frontend`;
only task 6.3 is blocked on this group merging.

- [x] 1.1 Add a graph-request builder that composes `endpoints.graph` with `start` / `end`
      (Unix seconds) from the resolved view time range, plus the filter parameters, and
      verify its unit tests cover: no filters selected, every filter selected, repeated
      values for one dimension, and that an endpoint already carrying a query string is
      extended rather than clobbered.
- [x] 1.2 Feed the resolved time range and the selected filters into `useGraphLoader` so
      the URL is rebuilt per request, and verify existing `useGraphLoader` tests still
      pass plus a new one asserting that changing the time selection issues a request with
      a different window.
- [x] 1.3 Extend the runtime-config schema with the label-values base URL: add it to
      `RuntimeEndpoints`, `KNOWN_ENDPOINT_KEYS` and the `parseEndpointUrl` loop, and verify
      `validate.test.ts` covers accepting a root-relative value, accepting an absolute
      http(s) value, and rejecting a non-string.
- [x] 1.4 Add a label-values client that requests
      `<base>/api/v1/label/<name>/values?match[]=kube_pod_info` and parses
      `{"status":"success","data":[…]}`, and verify unit tests cover a success body, a
      non-success status field, a malformed body, and a network failure — a failure must
      leave the control empty and reportable, never throw into the graph load path.
- [x] 1.5 Add the filter control bar for `cluster`, `az`, `env`, `namespace`, `edge_type`
      and `prune`, with the four identity controls populated by task 1.4, `prune`
      defaulting to the traffic graph, and verify component tests assert the default
      projection and that a selection reaches the request builder.
- [x] 1.6 Distinguish a failed graph request from an empty one in the rendered state, and
      verify a test asserts the two produce different user-visible states
      (`frontend-graph-controls` → "A failure to reach the backend is reported, never
      rendered as emptiness").
- [x] 1.7 Run `make check` in the frontend repository (lint, typecheck, `fixture:check`,
      unit tests with coverage) and verify it exits zero, then open the PR.

## 2. The frontend chart in this repository

- [x] 2.1 Create `charts/kube-state-graph-frontend/` (Chart.yaml at version `0.1.0`,
      pinned `fullnameOverride`, `image.pullPolicy: Never`) and verify
      `helm lint charts/kube-state-graph-frontend` passes.
- [x] 2.2 Add the Deployment mounting the config ConfigMap as a **directory** at
      `/srv/config` (never `subPath`) and the replacement `nginx.conf` Secret over
      `/etc/nginx/nginx.conf`, with `KSG_API_PROXY_TARGET` deliberately unset, and verify
      `helm template` renders both mounts and no such env var.
- [x] 2.3 Add the NodePort Service pinned to `30300` targeting container port `8080`, and
      verify `helm template` shows the pinned nodePort.
- [x] 2.4 Add the `config.json` ConfigMap with `demoMode: false`, `endpoints.graph`
      `/api/v1/graph`, and the label-values base `/metrics-api`, and verify the rendered
      JSON parses with `jq` and contains no credential.
- [x] 2.5 Add the `nginx.conf` Secret template, derived from the image's shipped conf with
      its `/healthz`, `/config.json`, `/assets/` and SPA-fallback blocks kept verbatim,
      carrying `location /api/` → `http://kube-state-graph:8080/` and
      `location /metrics-api/api/v1/label/` → `http://vm-auth:8427/api/v1/label/` with an
      `Authorization: Basic` header rendered from `global.ksgUpstreamAuth`, and **no**
      `include /tmp/api_proxy.conf;`. Verify `helm template` emits exactly one
      `location /api/` and that the base64 credential decodes to the values in
      `global.ksgUpstreamAuth`.
- [x] 2.6 Add liveness and readiness probes on `/healthz` and verify `helm template`
      renders both.

## 3. Umbrella chart: add the frontend, remove Grafana

- [x] 3.1 Add the `kube-state-graph-frontend` dependency (`file://../kube-state-graph-frontend`,
      version `0.1.0`) to `charts/ksg-demo/Chart.yaml` and a values block wiring its image
      tag, and verify `helm template charts/ksg-demo` renders the frontend workload.
- [x] 3.2 Remove the `grafana` dependency from `charts/ksg-demo/Chart.yaml`, the entire
      `grafana:` values block (both datasources, the plugin init container, `grafana.ini`,
      `dashboardProviders`, `dashboardsConfigMaps`), `charts/ksg-demo/templates/dashboards-configmap.yaml`
      and `charts/ksg-demo/dashboards/`, and verify `helm template charts/ksg-demo` emits
      no Grafana object and `grep -ri grafana charts/` returns only the vendored directory
      still pending deletion in 3.3.
- [x] 3.3 Run `make vendor-charts` **online**, delete `charts/ksg-demo/charts/grafana/`,
      and verify `make deps` passes offline afterwards and `Chart.lock` no longer lists
      grafana.
- [x] 3.4 Update the `ksg-demo` chart description, which currently names "the Grafana panel
      that draws it", and verify `helm lint charts/ksg-demo` passes.

## 4. Build and iteration plumbing

- [x] 4.1 Rename `PANEL_SRC` / `PANEL_IMAGE` to `FRONTEND_SRC` / `FRONTEND_IMAGE` in the
      Makefile, point `image-frontend` at `-f $(FRONTEND_SRC)/Dockerfile $(FRONTEND_SRC)`,
      and verify `make image-frontend FRONTEND_SRC=../kube-state-graph-frontend` builds.
- [x] 4.2 Replace `make redeploy-panel` with `make redeploy-frontend` (build, `kind load`,
      `rollout restart`, `rollout status` against the frontend Deployment) and verify a
      source change is live after one invocation.
- [x] 4.3 Update `make load` and `make images` for the renamed image, and `make urls` to
      name the frontend on `:3001` instead of Grafana, and verify `make urls` output.
- [x] 4.4 Delete `docker/panel.Dockerfile` and verify no Makefile target or script still
      references it.
- [x] 4.5 Add `kube-state-graph-frontend` to `local_charts` in `scripts/charts-deps.sh`,
      drop grafana from its explanatory comment, and verify `make deps` packages four
      first-party subcharts plus the new one.

## 5. Harness: verification and readiness

- [x] 5.1 Add a frontend `/healthz` gate to `scripts/wait-ready.sh` alongside the existing
      storage-chain gates, and verify a cold `make up` blocks until the front door answers.
- [x] 5.2 Rewrite `verify.sh` section 10 to fetch `/config.json` from the frontend, assert
      it parses and has `demoMode: false`, then request the `endpoints.graph` path
      **through the frontend's origin** and assert a non-empty element set. Verify the
      section fails when the frontend is scaled to zero.
- [x] 5.3 Rewrite `verify.sh` section 11 to request the label-values path through the
      frontend for `cluster`, `az`, `env` and `namespace`, assert `cluster` contains the
      raw `ksg-demo` and does **not** contain the composed `local-a-demo-ksg-demo`, and
      verify the section names the store it queries in its header like every other section.
- [x] 5.4 Remove the `GRAFANA` variable and every Grafana datasource API call from
      `verify.sh`, and verify `bash -n scripts/verify.sh` passes and no `grafana` string
      remains.
- [x] 5.5 Confirm `make verify` still reads
      `kube_state_graph_backend_query_failures_total` as a delta and that section
      numbering 1–11 is intact, and verify a full `make verify` run is green.

## 6. Submodule swap

- [x] 6.1 Remove the `kube-state-graph-panel` submodule (`git submodule deinit`, `git rm`,
      clear `.git/modules/kube-state-graph-panel`) and verify `.gitmodules` no longer names
      it and `git submodule status` is clean.
- [x] 6.2 Add `kube-state-graph-frontend` as a submodule over **HTTPS**
      (`https://github.com/akira-core/kube-state-graph-frontend`) tracking
      `feat/pure-ui-frontend`, and verify `git submodule update --init --recursive` works
      from a fresh clone with no SSH key.
- [x] 6.3 Pin the submodule to the merge commit from task 1.7 and verify `make up` builds
      the frontend from the submodule with no `FRONTEND_SRC` override. **Blocked on group 1
      merging.**

## 7. Documentation

- [x] 7.1 Update `CLAUDE.md`: the submodule table, the entry-points paragraph (Grafana on
      3001 → the frontend on 3001), the "Where things live" table, the dashboard invariant
      in "Invariants that fail silently" (replaced by the front-door request contract), and
      the debugging order's step 3 note about which store to ask. Verify every path and
      command it names exists.
- [x] 7.2 Update `README.md`: the pipeline diagram's front end, the entry-point list, the
      "what is real vs faked" section, and the troubleshooting table rows that name Grafana
      or the panel. Verify no `grafana` or `panel` reference survives except in history.
- [x] 7.3 State explicitly in both documents that ad-hoc PromQL now goes to vmselect
      (`:18481`) and vmauth (`:18427`) directly, with the `curl -u` form for the
      authenticated store, and verify both commands work against a running demo.

## 8. End-to-end acceptance

- [x] 8.1 Run `make lint` and verify it passes for `tools/` and all six charts.
- [x] 8.2 Run `make down && make up` from a clean checkout and verify bring-up completes
      without a `FRONTEND_SRC` override.
- [x] 8.3 Run `make verify` and verify all eleven sections are green.
- [x] 8.4 Open `http://localhost:3001` and verify by hand: the graph draws from live data
      (not the showcase fixture), the time picker changes the window and redraws, each of
      the six controls changes what is drawn, the cluster control offers `ksg-demo` and not
      `local-a-demo-ksg-demo`, and the projection control's unpruned position reconciles
      the pod count with `make verify`.
- [x] 8.5 Verify the served `/config.json` and every browser-visible response carry no
      credential, and that the label-values requests succeed without the browser sending
      one.
