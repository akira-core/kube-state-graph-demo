Ordering follows `design.md` — Migration Plan: the demo is never left without volume
statistics, and the graph is captured before it is changed so every claim about
"unchanged behaviour" is a diff rather than an assertion.

Groups 1–4 are independent of group 5 only in the sense that a storage failure does not
block the dashboard work. Within each group, order is dependency order.

## 1. Real volume statistics from the kubelet

- [ ] 1.1 Add `csi-driver-nfs` and an in-cluster NFS server as pinned dependencies of the umbrella chart, and vendor them unpacked with `make vendor-charts`; verify `make deps` succeeds with `HTTP_PROXY`/`HTTPS_PROXY` blackholed and `helm template` still renders.
- [ ] 1.2 Point the `netapp-nas` StorageClass at the NFS driver in place of the local-path provisioner, sizing the export large enough for every demo claim (design Open Question 1 — the figure is a non-goal; use a single 20Gi export unless it proves too small); verify every demo claim reaches `Bound` and every PVC-backed pod reaches `Running`.
- [ ] 1.3 **Assumption gate.** Confirm the kubelet publishes `kubelet_volume_stats_used_bytes` and `_capacity_bytes` for the demo claims, by reading each node's metrics through the API-server proxy — the same check that currently returns zero series on all three nodes. If it returns nothing, stop and switch to `csi-driver-host-path` per design Decision 1 before continuing; do not proceed to group 2 on an unproven driver.
- [ ] 1.4 Confirm the series reach the metric store carrying `cluster`, `az` and `env`; verify `count by (az, env) (kubelet_volume_stats_used_bytes)` returns a result and that a claim's used value is non-zero for a workload that has written data.
- [ ] 1.5 Confirm the graph resolves claim usage end to end while both sources are still present; verify `/v1/graph` returns claims carrying usage figures, and save this response as the storage baseline for task 2.4.

## 2. Retire the simulated volume statistics

- [ ] 2.1 Remove `emitVolumeStats` from the umbrella values and from the `netapp-faker` chart values; verify `helm lint` passes for both charts and `helm template` renders no `EMIT_VOLUME_STATS` environment variable.
- [ ] 2.2 Remove the kubelet legs from the faker binary — the `VolumeStats` config field, its environment parsing, the `kubelet_volume_stats_*` block in `claimSamples`, and the `fallbackClaimCapacityB` constant that served only it; verify `gofmt -l` is clean and `go vet ./...` passes in `tools/`.
- [ ] 2.3 Redeploy and confirm the ONTAP simulator still emits its array families and nothing else; verify `volume_labels`, `qos_*` and `aggr_*` are present while no `kubelet_volume_stats_*` series carries the simulator's job or instance labels.
- [ ] 2.4 Confirm claim usage survives the removal; verify `/v1/graph` still returns claims carrying usage figures, matching the baseline saved in task 1.5 apart from the values themselves.
- [ ] 2.5 Remove `kube_persistentvolumeclaim_resource_requests_storage_bytes` from the kube-state-metrics allowlist if nothing else reads it; verify the graph is unchanged, and leave it in place with a comment if it turns out to be load-bearing.

## 3. Pod-level ArgoCD Application

- [ ] 3.1 Capture the current graph as the application baseline — node set, edge set, and each pod's resolved owner; verify the capture is stored where task 3.6 can diff against it.
- [ ] 3.2 Stamp the demo workloads' pod templates with the GitOps instance label naming each workload's application, matching the application its Service and claims already declare; verify `kubectl get pods --show-labels` shows the label on every workload pod.
- [ ] 3.3 Extend the kube-state-metrics `metricLabelsAllowlist` to pods for that label; verify `kube_pod_labels` returns a non-empty `label_app_kubernetes_io_instance` for the demo's workload pods.
- [ ] 3.4 Add `vmalert` as a pinned dependency, vendor it unpacked, and wire it to read from vmselect and write to vminsert; verify `make deps` still succeeds offline and the vmalert pod reaches `Ready` with its rule group loaded.
- [ ] 3.5 Add the recording rule that joins the instance label onto `kube_pod_owner` as `argocd_tracking_id`, using the expression in design Decision 3; verify `count(kube_pod_owner{argocd_tracking_id!=""})` returns one series per application-owning pod.
- [ ] 3.6 Confirm the additive rule did not disturb the rest of the graph; verify against the task 3.1 baseline that application group nodes are the only addition — every pod still resolves to exactly one owner, no pod appears twice, and the edge set is byte-identical.
- [ ] 3.7 Confirm graceful degradation; verify that with vmalert scaled to zero and a window past the rule's last output, the graph still returns every pod under its controller and simply carries no application grouping, with no build error.

## 4. The repository owns its dashboards

- [ ] 4.1 Make `charts/ksg-demo/dashboards/` tracked source: commit the demo dashboard, delete the text panel describing the panel repository's `dev/victoriametrics/topology.prom` fixture, and stop provisioning the backend-free showcase dashboard; verify the provisioned dashboard list contains only the backend-backed dashboard and that no dashboard JSON mentions a fixture this repository does not contain.
- [ ] 4.2 Remove `sync-dashboards` from the `make up` chain and rename it to an explicit import target that reports which files it overwrote; verify `make up` no longer invokes it and the import target still copies from the panel submodule when run on purpose.
- [ ] 4.3 Confirm bring-up no longer depends on the panel repository for dashboards; verify the demo provisions its dashboards with the panel submodule's working tree emptied, and that an edit made to a tracked dashboard survives a subsequent `make up`.
- [ ] 4.4 Confirm the dashboard still renders the graph from the running backend; verify the panel draws the topology in Grafana and that the drawing changes after a workload is scaled.

## 5. Verification harness and documentation

- [ ] 5.1 Extend `scripts/verify.sh` with checks in data-flow order for the newly real signals — real volume statistics present and carrying `az`/`env`, and `kube_pod_owner` carrying a non-empty `argocd_tracking_id`; verify the script reports them as `ok` against a healthy demo (design Open Question 2 resolved: assert both).
- [ ] 5.2 Add a negative check asserting no `kubelet_volume_stats_*` originates from the simulator, so the script proves the data is real rather than merely present; verify it fails if `netapp-faker` is made to emit them again.
- [ ] 5.3 Update `README.md`: retire both entries of "What the demo cannot show", move the shared-export capacity caveat into the honest-caveats list, and correct the "What is real and what is not" table; verify no statement in the README contradicts what `make verify` reports.
- [ ] 5.4 Update `CLAUDE.md`: add the recording rule and the CSI precondition to the silent-failure list, and remove the volume-stats caveat from the deliberate-negative-cases list while keeping `redis-data`; verify the file describes the pipeline as built.
- [ ] 5.5 Full cold run from an empty machine state; verify `make down && make up && make verify` completes with every check passing and all six edge types present, and that the Helm phase of bring-up performs no network access.
