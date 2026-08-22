## Context

See `proposal.md` — Why. Requirements are in `specs/`; this document records how they
are met and why each alternative was rejected.

Two facts shape everything below.

**The kubelet reports nothing for the demo's current volumes.** Measured on the running
three-node cluster: `kubelet_volume_stats_*` returns zero series on every node, and
`/stats/summary` reports an empty volume list for the three PVC-backed pods. kind's
local-path provisioner produces hostPath-backed PersistentVolumes, and that volume
plugin implements no stats provider, so there is nothing to scrape. Replacing the
provisioner is therefore not an optimisation; it is the only way these series can exist.

**Both candidate CSI drivers report the backing filesystem, not the volume.** Read from
source rather than assumed: `csi-driver-host-path` creates a Filesystem-mode volume with
`os.MkdirAll` — a plain directory on the node — and its `getPVStats` is a statfs;
`csi-driver-nfs` calls `volume.NewMetricsStatFS(volumePath)`. Neither yields a capacity
specific to one claim. Only a driver that gives each volume its own filesystem (LVM- or
ZFS-backed) would, and that is a different class of dependency.

This demo's purpose is to prove the **metric contract**: that every series the graph
reads exists, is named as the graph expects, carries the labels the graph joins on, and
survives every hop to the rendered output. Numeric fidelity of the reported figures is
not what it demonstrates, and the specs were written accordingly.

## Goals / Non-Goals

**Goals:**

- Every series the graph reads comes from the component a production cluster reads it
  from — the kubelet for volume statistics, kube-state-metrics for topology, the
  collector for service-graph edges.
- The pod → ArgoCD Application association is observable in the metric store, so the
  graph nests pods under an application group.
- Losing any newly added component degrades the graph rather than emptying it.
- The demo's dashboards are this repository's own, and bring-up does not overwrite them.
- The Helm phase of bring-up keeps working with no network.

**Non-Goals:**

- Per-claim numeric accuracy of reported capacity. Claims sharing a backing filesystem
  will report the same capacity; that is accepted.
- Replacing the ONTAP simulator. Array-side telemetry stays synthesised.
- Platform hardening (metric-store authentication and persistence, non-anonymous
  Grafana, a second cluster) — out of scope per the proposal.
- Making the container-image half of bring-up work offline. That was already open before
  this change and stays open.

## Decisions

### Decision 1: Provision the demo StorageClass with `csi-driver-nfs` against an in-cluster NFS server

The `netapp-nas` StorageClass is consumed the way a NetApp NAS backend actually is —
over NFS. An in-cluster NFS server exports one directory, and `csi-driver-nfs`
provisions a subdirectory per claim. The kubelet then reports `kubelet_volume_stats_*`
through the standard CSI `NodeGetVolumeStats` path, which is exactly the path a
production cluster uses.

*Why not `csi-driver-host-path`:* it is explicitly the CSI project's test driver, so it
argues against the "close to production" goal it would be adopted for. It also needs
more sidecars assembled by hand (provisioner, attacher, resizer, snapshotter,
registrar, liveness probe) and ships no official Helm chart, so it would be the heavier
of the two to vendor for offline bring-up — while reporting capacity no better.

*Why not an LVM- or ZFS-backed CSI driver:* it is the only class that would report a
genuine per-claim capacity, but it needs a privileged DaemonSet doing loop-device and
volume-group setup inside the kind nodes, and it models block-local storage — a worse
fit for a StorageClass named after a NAS. Since per-claim capacity is a non-goal, the
cost buys nothing this demo needs.

### Decision 2: Accept statfs capacity semantics and say so

Every claim on the shared NFS export reports that export's size as its capacity. This
is recorded in the README beside the demo's other honest caveats rather than papered
over.

*Why not derive capacity from the claim's request:* a recording rule could republish
`kubelet_volume_stats_capacity_bytes` from
`kube_persistentvolumeclaim_resource_requests_storage_bytes`, which is already scraped,
and the figure would match what NetApp Trident reports for a FlexVol sized to the
request. It was rejected because it re-introduces a derived series where the demo's
whole point is to show the real one arriving from the real source, and because it would
require suppressing the kubelet's own capacity series to avoid two sources for one
metric name — trading a cosmetic gain for a load-bearing complication.

### Decision 3: Publish the pod → Application association with a `vmalert` recording rule, additively

The demo workloads' pod templates carry the instance label a GitOps controller stamps on
what it manages. kube-state-metrics exposes it on `kube_pod_labels` via
`metricLabelsAllowlist`. A `vmalert` recording rule joins that label onto
`kube_pod_owner` and republishes it under the same name, renamed to the
`argocd_tracking_id` label the graph reads:

```
record: kube_pod_owner
expr: |
  label_replace(
    kube_pod_owner * on (cluster, namespace, pod) group_left (label_app_kubernetes_io_instance)
      kube_pod_labels,
    "argocd_tracking_id", "$1", "label_app_kubernetes_io_instance", "(.+)"
  )
```

The graph takes the segment before the first `:` and surfaces a colon-less value
verbatim, so a bare application name resolves correctly with no grammar to construct.

*Why additive, accepting a duplicate series:* the recorded copy coexists with the
scraped `kube_pod_owner`, so each pod yields two rows differing only by the added label.
The alternative — renaming the scraped series and making the rule's output the only
`kube_pod_owner` — removes the duplication but makes the rules engine load-bearing for
the entire pod-to-controller relationship: if `vmalert` stops, the graph loses every
pod's owner. The additive form fails much better. If `vmalert` stops, pods keep their
owners and only the application grouping degrades, which is the behaviour
`pod-application-grouping` already requires. The cost is duplicated `kube_pod_owner`
cardinality, which at this demo's size is negligible.

The graph builder is duplicate-tolerant by construction — it resolves multi-sample joins
by lexicographic pick and skips empty tracking ids — so the duplicate is expected to be
harmless. "Expected" is not "verified", which is why `pod-application-grouping` requires
controller resolution and the edge set to be unchanged, and why verification compares
the graph before and after.

*Why not a backend code change:* the second route the backend's preconditions document
names would give pods the annotation path services and claims already use, but it means
changing a submodule and an OpenSpec change in another repository to add a demo
capability. The recording rule needs neither.

### Decision 4: The repository owns its dashboards; importing becomes explicit

`charts/ksg-demo/dashboards/` becomes tracked source. `sync-dashboards` leaves the
`make up` chain and is renamed to an explicit import target that reports what it
overwrote. The panel repository's dev-fixture text panel is deleted from the demo's copy,
and the backend-free showcase dashboard is not provisioned — a deployment that has a
working backend has no reason to ship a demonstration of one that does not.

*Why not keep syncing and patch afterwards:* any post-copy edit is overwritten on the
next bring-up, which is the defect being fixed.

### Decision 5: New dependencies are vendored the way the existing ones are

`vmalert` and `csi-driver-nfs` are added as pinned chart dependencies and vendored
unpacked under `charts/ksg-demo/charts/` via `make vendor-charts`, keeping `make deps`
offline. Their container images enlarge the image side of offline bring-up, which is
already open and is not addressed here.

## Risks / Trade-offs

- **The duplicate `kube_pod_owner` changes graph output in a way not predicted** →
  `pod-application-grouping` requires the controller resolution and edge set to be
  unchanged; verification captures the graph before the rule is introduced and diffs it
  after, so a regression is caught rather than shipped.

- **`csi-driver-nfs` does not report volume statistics in kind as expected** → this is
  the assumption the whole storage half rests on, and it is read from source rather than
  measured. The first implementation task is to stand the driver up and confirm the
  series appear, before anything is removed from `netapp-faker`. If it fails,
  `csi-driver-host-path` is the fallback at equal capacity fidelity.

- **The NFS server becomes a single point of failure for every demo claim** → acceptable
  for a laptop demo, and it fails loudly (pods stuck mounting) rather than silently,
  unlike most failure modes in this pipeline.

- **Removing `emitVolumeStats` is irreversible for anyone running the faker outside this
  demo** → the option exists only in this repository's chart and its own binary, and the
  proposal marks it BREAKING.

- **The vendored set and image count grow, making a cold `make up` slower and the
  offline gap wider** → the Helm phase stays offline, which is the part this repository
  has committed to; the image gap is recorded as still open rather than quietly widened.

## Migration Plan

Ordered so the demo is never left without volume statistics:

1. Stand up the NFS server and `csi-driver-nfs`; point `netapp-nas` at it. Confirm
   `kubelet_volume_stats_*` appears for demo claims while the faker is still emitting
   its own. Both sources are present here — an expected, temporary overlap.
2. Remove `emitVolumeStats` from the chart, then the kubelet legs from the faker binary.
   Confirm the series survive and now come only from the kubelet.
3. Add the pod instance label, the kube-state-metrics allowlist entry, and `vmalert`
   with the recording rule. Diff the graph against the capture from step 2.
4. Move the dashboards to repository ownership and rework the make targets.
5. Update `scripts/verify.sh`, `README.md` and `CLAUDE.md`.

Rollback: each step is a Helm value or chart change and reverts by reinstalling the
previous chart. Steps 1–3 are independent of 4, so a storage problem does not block the
dashboard work.

## Open Questions

- Which NFS server image and export sizing to use. It affects the reported capacity
  figure, which is a non-goal, and changes no spec, approach or task.
- Whether `verify.sh` should assert the absence of simulated volume statistics or only
  the presence of real ones. Both are cheap; the choice can be made while writing the
  check.
