## Why

The demo's whole claim is that almost nothing in it is invented: real workloads make
real calls, real kube-state-metrics reports real objects, and exactly one component —
`netapp-faker` — stands in for hardware a laptop cannot have. Three things currently
break that claim.

Two of them are data the real Kubernetes stack can produce and the demo does not use.
`kubelet_volume_stats_*` is synthesised by `netapp-faker` rather than measured, even
though the workloads genuinely write bytes to their claims; only the *reporting* is
fake. And pod-level ArgoCD Application is simply absent, so pods nest under
`cluster > namespace > controller > pod` instead of the `application` level the
backend already supports — the README lists this as something the demo "cannot show",
which is true only of stock kube-state-metrics, not of a real deployment.

The third is the dashboard. `make sync-dashboards` copies the panel repository's
provisioned dashboards verbatim into this chart on every `make up`. Those are the
panel repo's *development fixtures*: the shipped "KSG Demo" dashboard carries a text
panel describing `dev/victoriametrics/topology.prom`, a seed file this demo does not
use and does not contain. The demo's front door therefore explains a system that is
not the one running behind it, and any edit made here is silently overwritten on the
next bring-up.

## What Changes

- **Real kubelet volume stats.** Provision the `netapp-nas` StorageClass through a CSI
  driver that implements `NodeGetVolumeStats`, replacing kind's local-path provisioner
  for that class. The kubelet then reports genuine `kubelet_volume_stats_used_bytes` /
  `_capacity_bytes` for demo claims, measured from the bytes the workloads actually
  write.
  - **BREAKING** for `netapp-faker`: the `emitVolumeStats` option and the kubelet legs
    of `claimSamples` are removed, not merely defaulted off. After this change the
    faker emits array-side ONTAP telemetry only.
  - The choice of CSI driver is deliberately not fixed here. It is settled in
    `design.md` by a measurement — what each candidate actually reports as a claim's
    `capacity_bytes` — because a driver that reports the backing filesystem's size for
    every claim would be a regression against the per-claim sizing the faker does today.

- **Pod-level ArgoCD Application.** Stamp the demo workloads' pod templates with an
  instance label the way ArgoCD stamps resources it manages, expose it through
  kube-state-metrics, and add a `vmalert` recording rule that joins it onto
  `kube_pod_owner` as the `argocd_tracking_id` label the backend reads. Pods then nest
  under `cluster > namespace > application > controller > pod`, and the PVC Application
  inheritance path (an app-less claim borrowing from its mounting pods) has something
  to borrow. This is route 1 of the two the backend's
  `docs/kube-state-metrics-preconditions.md` names as honest; it needs no change to the
  backend.
  - Adds `vmalert` to the release. The demo currently has no rules engine.

- **The demo becomes the sole owner of its dashboards.** `charts/ksg-demo/dashboards/`
  becomes authored source rather than a copy target, and its dev-fixture text panel is
  removed. Pulling the submodules to their current branches settled how far this goes:
  the panel repository deleted `provisioning/dashboards/ksg-demo.json` in `bf1a7c9`
  ("render the demo from a typed fixture, drop the backend stack"), so this repository
  now holds the last copy, and what a sync would fetch instead is a generated fixture
  dashboard. `sync-dashboards` is therefore deleted outright rather than kept as an
  opt-in import — an import that can only destroy is not worth a door.
  - **BREAKING** for anyone relying on `make up` to refresh dashboards from the panel
    submodule, and for anyone invoking `make sync-dashboards`: both are gone.

- **The dashboard's filters stop depending on the graph API.** The backend's `/v1` group
  now serves only `/v1/graph` and `/v1/edge-types`; the dashboard's `Cluster` variable
  still queries the removed `/v1/clusters` and gets a `404` — live today, and invisible,
  because under "All" the empty interpolation simply applies no filter and the graph
  draws fine. The `cluster`, `env` and `namespace` filters move to `kube_pod_info` label
  queries, which is where the backend's own filters match anyway, and an `env` filter is
  added so the backend's environment path is exercised at all. That every URL the
  dashboard calls resolves becomes something `make verify` asserts.
  - The `Resource name` filter goes with it. The backend withdrew `?name=` alongside
    `/v1/clusters` and ignores unknown parameters silently, so the control populated,
    accepted a selection and changed nothing — the dead-endpoint failure one layer in,
    where the dropdown is full instead of empty and therefore looks right.
  - A `Projection` control is added for the backend's `?prune=`. The dashboard sent no
    `prune` and so inherited the pruned default, drawing 8 of the cluster's 38 pods,
    while `scripts/verify.sh` asserts against `prune=false` — two artifacts in this
    repository disagreeing by 30 pods with nothing saying so. The default position is
    unchanged behaviour; the second reaches the estate the prune removes.

- **Documentation follows.** The README's "What the demo cannot show" section loses
  both of its entries; `scripts/verify.sh` gains a check per newly-real signal, in the
  same data-flow order as the existing ones.

Explicitly out of scope: platform-level production hardening (VictoriaMetrics
authentication and persistence, non-anonymous Grafana, a second cluster). The ONTAP
array stays faked — it is the one thing that genuinely cannot exist here.

## Capabilities

`openspec/specs/` is empty, so every capability below is new. Paths are flat
kebab-case; this repository is itself the demo, so a `demo/` prefix would be noise.

### New Capabilities

- `storage-provisioning`: How the demo provisions PersistentVolumeClaims and where each
  claim's capacity and usage figures come from. Covers the CSI requirement that claims
  on the demo StorageClass yield real `kubelet_volume_stats_*`, the boundary between
  measured Kubernetes storage data and synthesised ONTAP array telemetry, and the
  deliberate control case of a claim left on the default StorageClass.
- `pod-application-grouping`: How a pod acquires its ArgoCD Application. Covers the
  label the workload templates carry, its exposure through kube-state-metrics, the
  recording rule that republishes `kube_pod_owner` with `argocd_tracking_id`, and the
  requirement that a pod with no Application degrades to the controller nesting rather
  than erroring.
- `dashboard-provisioning`: Which dashboards the demo ships, that this repository is
  their source of truth, and that importing from the panel repository is an explicit
  operator action rather than a step in bring-up.

### Modified Capabilities

None. No spec exists yet under `openspec/specs/`.

## Impact

Charts and values:
- `charts/ksg-demo/Chart.yaml`, `Chart.lock`, `values.yaml` — new `vmalert` dependency,
  new CSI driver dependency, `netapp-faker.emitVolumeStats` removed, kube-state-metrics
  `metricLabelsAllowlist` extended to pods.
- `charts/demo-workloads/` — StorageClass provisioner changes; pod templates gain the
  instance label.
- `charts/netapp-faker/` — `emitVolumeStats` value removed.
- `charts/ksg-demo/dashboards/` — becomes a source directory; one panel removed.
- `charts/ksg-demo/templates/` — a recording-rule ConfigMap or equivalent for vmalert.

Code:
- `tools/cmd/netapp-faker/` — `config.go` (`VolumeStats`), `render.go` (kubelet legs of
  `claimSamples`) and the `fallbackClaimCapacityB` constant that only served them.

Build and scripts:
- `Makefile` — `sync-dashboards` deleted, along with `scripts/sync-dashboards.sh`.
- `scripts/verify.sh` — checks for real volume stats, for the recording rule's output,
  and that every backend URL the provisioned dashboards call resolves.
- `scripts/vendor-charts.sh` / `charts-deps.sh` — unchanged in behaviour; the vendored
  set grows by two charts.

Dependencies:
- Two new upstream charts. Every chart dependency this demo installs must be vendored
  in-tree — pinned in `Chart.lock` and tracked unpacked under `charts/ksg-demo/charts/`
  — so a version bump is a reviewable diff and bring-up never re-resolves a pin against
  a repo index. Their container images are pulled as usual; this change makes no claim
  about running with no network.

Documentation:
- `README.md` — "What is real and what is not" table, "What the demo cannot show"
  section (both entries retired), the layout and troubleshooting notes.
- `CLAUDE.md` — the silent-failure list gains the recording rule and the CSI
  precondition; the deliberate-negative-cases list keeps `redis-data` but loses the
  volume-stats caveat.
