## Purpose

Defines where the demo's storage figures come from: which claims are backed by
provisioning the kubelet can measure, and where the boundary sits between storage data
Kubernetes genuinely reports and array telemetry that is synthesised because no array
exists.

## ADDED Requirements

### Requirement: Claims on the demo StorageClass yield kubelet volume statistics

Persistent volume claims bound through the demo's NetApp-backed StorageClass SHALL
result in `kubelet_volume_stats_used_bytes` and `kubelet_volume_stats_capacity_bytes`
series reaching the metric store for the pods that mount them.

This is the contract the demo exists to prove: the series the graph reads are present,
named as the graph expects, and carry the identity the graph joins on. Numeric fidelity
of the reported figures is not part of this requirement.

#### Scenario: A mounted claim is reported

- **WHEN** a demo workload pod is running with a claim bound through the demo's
  NetApp-backed StorageClass
- **THEN** `kubelet_volume_stats_used_bytes` and `kubelet_volume_stats_capacity_bytes`
  are queryable for that claim
- **AND** both series carry the claim's `namespace` and `persistentvolumeclaim` identity

#### Scenario: Reported figures are usable

- **WHEN** those series are queried
- **THEN** each returns a non-negative value
- **AND** the reported capacity is greater than zero

### Requirement: Volume statistics originate from the kubelet

`kubelet_volume_stats_*` SHALL be produced by scraping the kubelet, which is the source
a production cluster reads them from. The ONTAP simulator SHALL emit array-side
telemetry only, SHALL NOT publish any series a real Kubernetes cluster would produce,
and the demo SHALL offer no option to turn such emission on.

#### Scenario: No simulated volume statistics exist

- **WHEN** the metric store is queried for `kubelet_volume_stats_used_bytes`
- **THEN** every returned series originates from a kubelet scrape
- **AND** no returned series originates from the ONTAP simulator

#### Scenario: The simulator still supplies array telemetry

- **WHEN** the metric store is queried for the ONTAP volume, aggregate, controller and
  QoS families
- **THEN** those series are present and are supplied by the ONTAP simulator

### Requirement: Reported values are live readings

The reported figures SHALL be readings taken from the volume as it exists, not values
generated independently of it. A figure that is computed from a seed or oscillated on a
timer regardless of the volume's contents SHALL NOT satisfy this requirement.

#### Scenario: Usage reflects a workload that has written data

- **WHEN** a workload has written data to its claim
- **THEN** the claim's reported used bytes is greater than zero

#### Scenario: A claim with no data written reports near-empty usage

- **WHEN** a claim is mounted by a workload that has written nothing to it
- **THEN** the claim's reported used bytes is small relative to its reported capacity

### Requirement: Volume statistics carry the labels filtered requests match on

`kubelet_volume_stats_*` series SHALL carry the same cluster, availability-zone and
environment labels as the rest of the demo's topology families, so that a request
filtered by availability zone or environment matches them rather than silently
returning a graph with no storage usage.

#### Scenario: A filtered request still resolves storage usage

- **WHEN** the graph is requested with an availability-zone or environment filter that
  matches the demo's workloads
- **THEN** claims in the returned graph still carry their usage figures

### Requirement: The graph resolves storage usage end to end

A claim's usage figures SHALL survive every hop between the kubelet and the rendered
graph, so that the demo demonstrates a working join rather than merely a populated
metric store.

#### Scenario: Claims in the built graph carry usage

- **WHEN** the graph is built over a window in which the demo has been running
- **THEN** claims on the demo's NetApp-backed StorageClass carry their usage figures in
  the returned graph

### Requirement: A claim outside the demo StorageClass acquires no array backing

A claim deliberately provisioned on the cluster's default StorageClass SHALL appear in
the graph as a claim with no storage chain behind it. This control case distinguishes
"never meant to have an array backend" from "should have joined and did not", and SHALL
be preserved.

#### Scenario: The control-case claim has no array chain

- **WHEN** the graph is built and contains the claim provisioned on the default
  StorageClass
- **THEN** that claim appears as a node in the graph
- **AND** no edge connects it to an ONTAP aggregate
