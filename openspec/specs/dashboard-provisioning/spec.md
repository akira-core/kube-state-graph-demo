# dashboard-provisioning Specification

## Purpose
Defines which dashboards the demo provisions and that this repository is their sole
source, now that the panel repository has deleted the backend-backed dashboard the demo
used to copy. Also defines the contract a provisioned dashboard owes the backend it
queries, since a dashboard calling an endpoint the backend no longer serves degrades
quietly rather than failing.

## Requirements

### Requirement: This repository is the sole source of the demo's dashboards

The dashboards the demo provisions SHALL be tracked source files in this repository. No
step of bringing the demo up SHALL replace them from another repository, so an edit made
here survives the next bring-up, and bring-up SHALL NOT depend on any other repository's
working tree for a dashboard.

#### Scenario: An edited dashboard survives bring-up

- **WHEN** a provisioned dashboard is edited in this repository and the demo is brought
  up again
- **THEN** the deployed dashboard reflects the edit

#### Scenario: Bring-up requires no other repository for dashboards

- **WHEN** the demo is brought up with the panel repository's working tree absent or
  empty
- **THEN** bring-up still provisions the demo's dashboards
- **AND** bring-up does not fail for want of a dashboard source

### Requirement: Replacing tracked dashboards from the panel repository is not a routine operation

The panel repository no longer publishes the backend-backed dashboard this demo
provisions; what it publishes is a fixture dashboard generated from its own typed
showcase data. Copying its dashboards over this repository's would therefore destroy the
only remaining copy of the demo's dashboard and replace it with one this specification
forbids provisioning.

No routine operation SHALL perform that copy. If a copy path is retained at all, it
SHALL report what it would destroy before doing so, and SHALL NOT be reachable by
accident.

#### Scenario: Bring-up never copies from the panel repository

- **WHEN** the demo is brought up
- **THEN** no dashboard file in this repository is written from the panel repository

#### Scenario: A retained copy path warns before destroying

- **WHEN** an operator invokes a retained copy path
- **THEN** it names the tracked dashboards it would overwrite or delete before acting

### Requirement: Provisioned dashboards call only endpoints the backend serves

Every backend request a provisioned dashboard makes SHALL target an endpoint the pinned
backend actually serves. A dashboard query against a removed endpoint SHALL be treated
as a defect, not as acceptable degradation: it fails quietly — the panel still draws,
and only a control that depends on the dead query comes up empty — which is precisely
the failure mode this demo exists to catch.

#### Scenario: Every dashboard request resolves

- **WHEN** each backend URL referenced by a provisioned dashboard is requested against
  the running demo
- **THEN** every one returns a success status
- **AND** none returns 404

#### Scenario: A dashboard control has a live data source

- **WHEN** a dashboard variable is populated from the backend
- **THEN** it is populated from an endpoint the backend serves
- **AND** the variable offers the values present in the running demo

### Requirement: A control that cannot change the graph is not shipped

A dashboard control SHALL either change what the graph returns or be removed. A control
whose request parameter the pinned backend no longer honours SHALL be treated as the
same defect as a control querying a removed endpoint: the backend ignores unknown
parameters without error, so the dropdown populates, the selection applies, the graph
redraws identically, and nothing anywhere reports that the filter did nothing.

#### Scenario: Every filter control moves the graph

- **WHEN** a value is selected in a dashboard filter control
- **THEN** the graph returned differs from the graph returned without that selection,
  for at least one value the control offers

#### Scenario: No request carries a withdrawn parameter

- **WHEN** the backend requests a provisioned dashboard makes are inspected
- **THEN** none carries a query parameter the pinned backend has withdrawn

### Requirement: Cluster, environment and namespace filters come from the pod inventory

The `cluster`, `env` and `namespace` filter controls SHALL be populated from the label
values carried by the pod inventory in the metric store, not from the graph API. The
backend pushes these filters upstream as raw label matchers against the same families,
so sourcing the options from the same labels guarantees that every value offered is one
the filter can act on.

The dashboard SHALL offer an environment filter. It does not today, and the backend's
environment filter path is otherwise exercised by nothing in the demo.

#### Scenario: Filters offer exactly the values the demo carries

- **WHEN** the dashboard loads against a running demo
- **THEN** the cluster, environment and namespace controls each offer the values present
  on the demo's pods
- **AND** under the unpruned projection none offers a value the graph filter would match
  nothing for

The qualification is load-bearing. The pod inventory spans every namespace the cluster
runs, while the default projection returns only the connectivity-connected subgraph, so
a namespace holding nothing that talks — the demo's own `monitoring`, or `kube-system` —
is offered and yields an empty graph until the projection control is switched. The
options track the inventory rather than the projection because the projection is a
per-request choice and the option list is not rebuilt per selection.

#### Scenario: Selecting a filter narrows the graph

- **WHEN** a value is selected in the cluster, environment or namespace control
- **THEN** the rendered graph is restricted to that value

#### Scenario: Filter controls survive a backend endpoint change

- **WHEN** the backend stops serving an endpoint the dashboard's other panels use
- **THEN** the cluster, environment and namespace controls are still populated

### Requirement: The dashboard exposes the backend's projection choice

The backend answers `/v1/graph` with the connectivity-connected subgraph unless asked
otherwise: a pod is kept only where it sits on a call or selection edge, and the node or
claim held only by dropped pods goes with it. The dashboard SHALL expose that choice as
a control rather than pinning it, because a viewer who cannot see the estate's
infrastructure has no way to tell a pruned graph from a broken pipeline.

The control SHALL default to the pruned projection, so the demo's front door is the
traffic graph. It SHALL reach every request the dashboard makes against the graph
endpoint, including the requests that populate other controls — a control enumerating
options from one projection while the panel draws another would offer values the panel
cannot show.

#### Scenario: The default projection is the traffic graph

- **WHEN** the dashboard loads with no control touched
- **THEN** the graph drawn is the connectivity-connected subgraph

#### Scenario: The unpruned projection reaches the infrastructure

- **WHEN** the projection control is switched to the unpruned setting
- **THEN** the graph includes pods carrying no call or mount edge, and the nodes and
  claims that hold only such pods

#### Scenario: Option lists follow the selected projection

- **WHEN** the projection control is switched and another control is repopulated from
  the graph endpoint
- **THEN** that control enumerates the projection currently selected

### Requirement: Provisioned dashboards describe only what the demo runs

A dashboard the demo provisions SHALL NOT describe fixtures, seed files, data sources or
behaviour that this demo does not run. Text that explains another repository's
development setup SHALL NOT be shipped, because the demo's front door would then explain
a system other than the one behind it.

#### Scenario: No dashboard references a fixture the demo lacks

- **WHEN** the provisioned dashboards are inspected
- **THEN** no dashboard references a seed file or fixture that this repository does not
  contain

#### Scenario: Dashboard text matches the running demo

- **WHEN** a provisioned dashboard explains where its data comes from
- **THEN** the explanation matches the pipeline this demo actually runs

### Requirement: The demo provisions a dashboard backed by the running backend

The demo SHALL provision a dashboard that renders the graph by querying the running
backend through the configured datasource. A dashboard that renders a fixture embedded
in its own definition SHALL NOT be provisioned, because the demo exists to show that the
backend produces a correct graph from correct data, and a fixture-rendered dashboard
demonstrates the panel instead.

#### Scenario: The provisioned dashboard reads from the backend

- **WHEN** the provisioned dashboard loads against a healthy demo
- **THEN** it renders the topology returned by the running backend
- **AND** the rendered content changes when the underlying cluster changes

#### Scenario: No fixture-rendered dashboard is provisioned

- **WHEN** the provisioned dashboards are listed
- **THEN** none of them renders from a fixture embedded in the dashboard definition
