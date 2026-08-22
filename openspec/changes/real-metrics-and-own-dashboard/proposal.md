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

- **The demo owns its dashboards.** `charts/ksg-demo/dashboards/` becomes a source
  directory in this repository rather than a copy target. The panel repo's
  dev-fixture text panel is removed. `sync-dashboards` leaves the `make up` chain and
  survives only as an explicit, opt-in import for pulling a newer panel-repo dashboard
  in on purpose.
  - **BREAKING** for anyone relying on `make up` to refresh dashboards from the panel
    submodule: it no longer does.

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
- `Makefile` — `sync-dashboards` leaves the `up` chain and is renamed to an explicit
  import target.
- `scripts/verify.sh` — checks for real volume stats and for the recording rule's
  output.
- `scripts/vendor-charts.sh` / `charts-deps.sh` — unchanged in behaviour, but the
  vendored set grows, enlarging the offline surface this repo just committed to.

Dependencies and offline bring-up:
- Two new upstream charts to vendor, plus their container images. `make up` is expected
  to keep working with no network for the Helm phase; the image side of offline
  bring-up was already an open item and this change makes it slightly larger.

Documentation:
- `README.md` — "What is real and what is not" table, "What the demo cannot show"
  section (both entries retired), the layout and troubleshooting notes.
- `CLAUDE.md` — the silent-failure list gains the recording rule and the CSI
  precondition; the deliberate-negative-cases list keeps `redis-data` but loses the
  volume-stats caveat.
