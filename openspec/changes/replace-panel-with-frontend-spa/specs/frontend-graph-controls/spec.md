## Purpose

Defines the contract the demo's front door owes the backend it draws: that every graph
request carries a current window, that every control the front door ships actually
changes what the backend returns, and that the identity filters offer only values the
backend can act on. These are the claims the retired Grafana dashboard used to carry, and
they fail quietly rather than loudly, which is why the demo asserts them.

## ADDED Requirements

### Requirement: Every graph request carries a current window

The backend requires an explicit `start` and `end` on every graph request and rejects a
request missing either. The front door SHALL therefore build its request rather than
issue a fixed URL, and the window it sends SHALL be derived from the time selection in
effect at request time.

A configured graph endpoint SHALL NOT be the sole source of the window. A window baked
into configuration is absolute, so it ages: it first stops moving, then falls outside the
stores' retention and returns an empty graph that is indistinguishable from a broken
pipeline.

#### Scenario: A fresh load sends a live window

- **WHEN** the front door loads and requests the graph
- **THEN** the request carries `start` and `end`
- **AND** the window ends at approximately the time of the request

#### Scenario: Changing the time selection changes the window

- **WHEN** a different time range is selected
- **THEN** the next graph request carries the window that selection resolves to
- **AND** the rendered graph is rebuilt from the response to that request

#### Scenario: The window does not age across reloads

- **WHEN** the front door is left open and refreshed after a long interval
- **THEN** the request it sends carries a window ending at approximately the current time
- **AND** not the window sent by the first request

### Requirement: The front door exposes the backend's filter dimensions

The front door SHALL offer controls for the dimensions the backend accepts on a graph
request: cluster, availability zone, environment, namespace, edge type, and the
projection choice. A selection SHALL be sent to the backend as a request parameter, so
the backend does the narrowing and the demo demonstrates that the filters reach upstream
queries.

Every shipped control SHALL change what the backend returns. The backend ignores an
unknown parameter without error, so a control whose parameter the backend does not honour
populates, accepts a selection, redraws identically, and reports nothing — a control that
cannot move the graph SHALL be removed rather than shipped inert.

#### Scenario: A selection reaches the backend

- **WHEN** a value is selected in any filter control
- **THEN** the next graph request carries that value as a request parameter

#### Scenario: A selection narrows the graph

- **WHEN** a value is selected in the cluster, availability-zone, environment or
  namespace control
- **THEN** the rendered graph is restricted to that value

#### Scenario: No control sends a parameter the backend has withdrawn

- **WHEN** the requests the front door makes are inspected
- **THEN** every parameter they carry is one the pinned backend honours

### Requirement: The projection control defaults to the traffic graph

The backend answers with the connectivity-connected subgraph unless asked otherwise: a
pod is kept only where it sits on a call or selection edge, and the node or claim held
only by dropped pods goes with it. The front door SHALL expose that choice as a control
rather than pinning it, because a viewer who cannot reach the estate's infrastructure has
no way to distinguish a pruned graph from a broken pipeline.

The control SHALL default to the pruned projection, so the demo's front door is the
traffic graph, and the demo's harness and the front door SHALL be understood to agree
only in the unpruned position.

#### Scenario: The default projection is the traffic graph

- **WHEN** the front door loads with no control touched
- **THEN** the graph drawn is the connectivity-connected subgraph

#### Scenario: The unpruned projection reaches the infrastructure

- **WHEN** the projection control is switched to the unpruned setting
- **THEN** the graph includes pods carrying no call or mount edge, and the nodes and
  claims that hold only such pods

#### Scenario: Fewer pods than the harness counts is the projection

- **WHEN** the front door in its default position shows fewer pods than the demo's
  verification walk reports
- **THEN** switching the projection control to the unpruned setting reconciles the two

### Requirement: Identity filter options come from the pod inventory

The `cluster`, `az`, `env` and `namespace` controls SHALL be populated from the label
values carried by `kube_pod_info` in the store that holds kube-state-metrics — not from
the graph response, and not from the cluster store, which holds no such family. The
backend pushes these filters upstream as raw label matchers against the same families, so
sourcing the options from the same labels is what guarantees every offered value is one
the filter can act on.

`cluster` SHALL offer the **raw** cluster label, never the composed
`<az>-<env>-<cluster>` identity the graph response lists. A value read out of that list
and sent back as a cluster filter matches no series and returns an empty graph with a
success status.

A graph request SHALL send all three identity components together, so a selection pins
one identity rather than every zone's cluster of the same raw name.

#### Scenario: Options are the values the demo carries

- **WHEN** the front door loads against a running demo
- **THEN** the cluster, availability-zone, environment and namespace controls each offer
  the values present on the demo's pods
- **AND** the cluster control offers the raw name, not the composed identity

#### Scenario: A listed identity is not a cluster option

- **WHEN** the graph response lists a composed cluster identity
- **THEN** the cluster control does not offer that identity
- **AND** it offers the raw cluster name instead

#### Scenario: Options survive a graph failure

- **WHEN** the graph request fails
- **THEN** the cluster, availability-zone, environment and namespace controls are still
  populated

#### Scenario: Options track the inventory, not the projection

- **WHEN** the projection control is in its default pruned position
- **THEN** the namespace control still offers every namespace the estate runs
- **AND** selecting a namespace holding nothing connected yields an empty graph rather
  than a missing option

The qualification is load-bearing. The pod inventory spans every namespace the cluster
runs, while the default projection returns only the connectivity-connected subgraph, so a
namespace holding nothing that talks is offered and yields an empty graph until the
projection control is switched. The options track the inventory because the projection is
a per-request choice and the option list is not rebuilt per selection.

### Requirement: A failure to reach the backend is reported, never rendered as emptiness

When a graph request fails or returns nothing, the front door SHALL say so. It SHALL NOT
present the result as an empty estate, because an empty canvas is exactly what a broken
pipeline produces and the demo exists to make that distinction visible.

#### Scenario: A failed request is named

- **WHEN** the graph request fails
- **THEN** the front door reports the failure and what it was requesting

#### Scenario: An empty response is distinguishable from a failure

- **WHEN** the graph request succeeds and returns no elements
- **THEN** the front door indicates that the request succeeded and the estate returned
  nothing, rather than showing the same blank state as a failed request
