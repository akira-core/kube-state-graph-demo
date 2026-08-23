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
- Every chart the release installs is vendored in-tree, so no dependency is resolved
  from a remote repo index at bring-up.

**Non-Goals:**

- Per-claim numeric accuracy of reported capacity. Claims sharing a backing filesystem
  will report the same capacity; that is accepted.
- Replacing the ONTAP simulator. Array-side telemetry stays synthesised.
- Platform hardening (metric-store authentication and persistence, non-anonymous
  Grafana, a second cluster) — out of scope per the proposal.
- Offline bring-up. Vendoring is required of the charts for pinning and reviewability,
  not as a step towards running with no network; images are pulled as usual.

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
of the two to vendor — while reporting capacity no better.

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
    kube_pod_owner{namespace=~"shop|platform",argocd_tracking_id=""}
      * on (cluster, namespace, pod) group_left (label_app_kubernetes_io_instance)
      kube_pod_labels{namespace=~"shop|platform"},
    "argocd_tracking_id", "$1", "label_app_kubernetes_io_instance", "(.+)"
  )
```

The left-hand `{argocd_tracking_id=""}` is required: the rule records under the
same name it reads, so an unguarded join matches both the scraped row and the
row it wrote last interval and VictoriaMetrics rejects the eval with
`duplicate output timeseries`. The backend's own preconditions document names
this ("give it a guarded expression or accept the idempotent re-join"). The
unguarded form in the first draft of this decision is that failure.

The `namespace=~"shop|platform"` matcher keeps the join on the demo's workload
namespaces. Every other pod in the release carries Helm's
`app.kubernetes.io/instance=<release>`, and joining that through would publish
`argocd_tracking_id="ksg-demo"` — a third-party Application the demo does not
declare.

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

### Decision 4: The repository becomes the sole owner of its dashboards; the sync is deleted, not renamed

Pulling the submodules to their current feature branches changed this decision's
premise. The panel repository's `bf1a7c9` — *"render the demo from a typed fixture, drop
the backend stack"* — **deleted** `provisioning/dashboards/ksg-demo.json`. What that
directory now holds is `default.yaml` and `ksg-switch-demo.json`, and the latter is
generated output: `dev/buildFixtureDashboard.mjs` compiles
`src/shared/fixtures/showcaseGraph.ts` into its inline target, with a `fixture:check`
that fails the build when the two drift.

So `charts/ksg-demo/dashboards/ksg-demo.json` is now the last copy of that artifact
anywhere, and `make sync-dashboards` would delete it and leave behind a fixture
dashboard this change forbids provisioning. The sync is therefore removed outright
rather than renamed to an opt-in import: an import that can only destroy is not a
feature worth keeping a door open for. `charts/ksg-demo/dashboards/` becomes ordinary
tracked source, authored here.

The panel repository's reasoning for dropping its own demo also settles a question this
change left implicit: it dropped the backend stack because the dashboard "never covered
the panel anyway" — `alerts`, `time_records`, `switch`, `network` and the fabric edge
types exist only in the panel, so only a fixture can exercise them. That is the panel
repository's job. This demo's job is the opposite one: show that the *backend* returns a
correct graph from correct data. The two repositories now test opposite halves, and
neither should ship the other's dashboard.

*Why not keep syncing and patch afterwards:* any post-copy edit is overwritten on the
next bring-up, which was the original defect — and the copy now also destroys.

*Why not vendor the panel's fixture dashboard as a second dashboard:* it demonstrates
the panel against known data, which is worth doing in the panel repository where the
fixture is typed and checked against the code that reads it. Shipped here it would be a
stale copy of generated output, asserting nothing about the backend.

### Decision 5: New dependencies are vendored the way the existing ones are

`vmalert` and `csi-driver-nfs` are added as pinned chart dependencies and vendored
unpacked under `charts/ksg-demo/charts/` via `make vendor-charts`. Vendoring is the
requirement: every chart the release installs is tracked here at the version
`Chart.lock` pins, so `make deps` never re-resolves against a repo index and a version
bump reviews as a diff. Their container images are pulled at bring-up like every other
image; this change makes no network claim beyond the charts.

### Decision 6: Filter variables come from `kube_pod_info`, not from the graph API

The backend's `/v1` group registers exactly two routes (`internal/api/server.go`):

```go
v1.GET("/graph", s.handleGraph)
v1.GET("/edge-types", s.handleEdgeTypes)
```

`GET /v1/clusters` is gone, and the demo's dashboard still queries it for the `Cluster`
variable — verified against the running backend, which answers `404`. This is live
today, not latent, and it fails in the way this repository keeps warning about: under
`$__all` the interpolation `${cluster:customqueryparam:cluster:}` expands to nothing, so
no filter is applied, the graph draws correctly, and only the dropdown is empty. A
reviewer looking at the panel sees a working demo.

The `cluster`, `env` and `namespace` variables are therefore sourced from
`kube_pod_info` through the VictoriaMetrics datasource the release already provisions,
as label queries rather than API calls. `env` is new — the dashboard has no environment
filter today.

Three reasons, in order of weight:

1. **The dropdown offers exactly what the filter can act on.** `cluster`, `az` and `env`
   are stamped onto every topology family by the collector, and the backend pushes
   `?az=` / `?env=` upstream as raw label matchers against those same families. Sourcing
   the options from the label values means a value can never be offered that the filter
   would then match nothing for — the two read the same labels.
2. **It decouples the controls from the backend's endpoint surface.** `/v1/clusters`
   disappearing emptied a dropdown silently; a label query cannot break that way when
   the API changes, which is the failure this change is closing.
3. **It stops a variable from building a whole graph.** `namespace` is currently
   populated by issuing `/v1/graph` over the dashboard's time range, so every dashboard
   load or refresh costs an extra full build purely to enumerate options.

`edge_type` stays on the backend: it is a static catalogue and `/v1/edge-types` is
exactly the authoritative source for it.

`name` is deleted outright rather than repointed. Measured against the running backend,
`?name=` changes nothing — `&name=redis` returns the same 35 nodes as no parameter at
all — because the pinned backend withdrew `name`, `root`, `depth` and `direction` along
with `/v1/clusters`, and it ignores unknown parameters without error. The control
therefore populated, accepted a selection, and moved nothing. That is the same silent
failure as the dead `/v1/clusters` query, one layer in: there the dropdown was empty and
visibly wrong, here it is full and looks right. Nothing in the panel reads the variable
either — `kube-state-graph-panel` only ever *writes* dashboard variables
(`alert_pod_list`, `alert_names`, `selected_pod`, `cluster_sel`), and its own
`Search nodes` box filters client-side — so removing it costs the demo nothing.

Adding `env` is not scope creep: the backend's `?env=` filter path is currently
exercised by nothing in the demo, and this change is about proving the metric contract
end to end. `?az=` is available on the same terms and is left out only because it was
not asked for.

*Why not repoint `Cluster` at `/v1/graph`'s `clusters` array:* it works — the response
carries the field, and `scripts/verify.sh` already prints it — but it keeps the control
coupled to the API surface that just broke it, and it keeps paying for a graph build to
populate a dropdown.

*Why not restore `/v1/clusters` in the backend:* it is another repository's deliberate
removal, made while pushing request filters upstream. Reaching into a submodule to undo
that so a demo dashboard can keep an old query is backwards.

*Why the endpoint contract still becomes a spec requirement:* `edge_type` and the graph
panel still call the backend, so the same silent breakage can recur the next time the
pinned backend moves. The requirement makes "every URL the dashboard calls
resolves" something `make verify` asserts, so the next removal is caught by the harness
rather than by someone noticing an empty dropdown.

### Decision 7: The connectivity prune becomes a dashboard control, not a pinned value

`/v1/graph` defaults to `prune=true` — the connectivity-connected subgraph — and the
dashboard sent no `prune` at all, so it inherited that default. Measured on the running
demo over a fifteen-minute window: the panel drew 8 pods across 2 namespaces where the
cluster runs 38 across 5. Dropped were every `monitoring` and `kube-system` pod, the
control-plane node, the NFS server's own claim, and three `shop` replicas that happened
to take no traffic in the window — one replica of a Deployment drawn, its sibling not.

Meanwhile `scripts/verify.sh` and `scripts/wait-ready.sh` both request `prune=false`.
The harness asserted against the inventory while the dashboard drew the traffic graph,
and the two disagreed by 30 pods with nothing saying so. `make verify` reporting
`pod: 38` next to a panel showing 8 is the kind of discrepancy this repository exists to
surface, not to contain.

The dashboard therefore carries a `Projection` variable — `Traffic graph` (`true`,
default) and `Full inventory` (`false`) — threaded into every `/v1/graph` URL the
dashboard builds. The default is unchanged behaviour, so the front door still opens on
the traffic graph; the second position makes the pruned-away estate reachable without
leaving Grafana, and is the position that agrees with the harness.

*Why not pin `prune=false` and drop the control:* the inventory draws the whole
`kube-system` and `monitoring` estate, which is noise against a demo whose point is the
call graph, and it would hide the prune — the backend's most consequential default —
behind a URL nobody reads.

*Why not leave the default and only document it:* the discrepancy is between two
artifacts in this repository, and a reader comparing them has no control to resolve it
with. Documentation explains the gap; the control closes it.

*Why thread it through the option-enumerating requests too:* a variable populated from
one projection while the panel draws another offers values the panel cannot show — the
dead-dropdown failure again, arrived at from the opposite direction.

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

- **The vendored set and image count grow, making a cold `make up` slower** → accepted.
  Both charts are vendored the way the existing ones are, so the cost is repository size
  and pull time, not a new resolution path at install time.

- **`namespace` sourced from `kube_pod_info` enumerates only namespaces that contain
  pods** → a namespace holding services or claims but no pods would not be offered,
  where the current `/v1/graph`-sourced variable would offer it. Both demo namespaces
  run pods, so nothing is lost today; recorded because it is a real behavioural
  difference, not an equivalence.

- **Under the default projection the namespace control offers values that draw an empty
  graph** → `kube_pod_info` spans every namespace the cluster runs, while the pruned
  projection returns only what talks, so selecting `monitoring`, `kube-system` or
  `local-path-storage` yields zero nodes until `Projection` is switched to
  `Full inventory`. Accepted rather than fixed by narrowing the option list: the
  narrowing would have to hard-code the demo's two workload namespaces into a query
  whose whole point is that it reads what is actually running, and the empty result is
  now recoverable in one click rather than inexplicable. Recorded here because the
  dashboard spec's "offers exactly what the filter can act on" holds only in the
  unpruned position.

- **Variable options follow the metric store's retention, not the dashboard's window** →
  a namespace or cluster that has aged out of VictoriaMetrics stops being offered even
  while a longer dashboard window would still graph it. At two days' retention against a
  laptop demo this cannot arise; on a longer-lived deployment it would.

- **Deleting `sync-dashboards` is irreversible for anyone who used it** → the panel
  repository no longer publishes the dashboard it copied, so the target could only
  destroy; the proposal marks the removal BREAKING and the README says what replaced it.

## Migration Plan

Ordered so the demo is never left without volume statistics:

1. Stand up the NFS server and `csi-driver-nfs`; point `netapp-nas` at it. Confirm
   `kubelet_volume_stats_*` appears for demo claims while the faker is still emitting
   its own. Both sources are present here — an expected, temporary overlap.
2. Remove `emitVolumeStats` from the chart, then the kubelet legs from the faker binary.
   Confirm the series survive and now come only from the kubelet.
3. Add the pod instance label, the kube-state-metrics allowlist entry, and `vmalert`
   with the recording rule. Diff the graph against the capture from step 2.
4. Move the dashboards to repository ownership, delete the sync, repoint the
   `cluster` / `env` / `namespace` variables at `kube_pod_info`, delete the withdrawn
   `name` filter, and add the `Projection` control. Confirm every URL the dashboard
   still calls resolves and that every remaining control changes the graph.
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
- Whether `az` deserves a dashboard variable alongside `env`. The backend filters on it
  identically and `kube_pod_info` carries it, so adding it later is a one-line change to
  the dashboard and no change to anything else.
