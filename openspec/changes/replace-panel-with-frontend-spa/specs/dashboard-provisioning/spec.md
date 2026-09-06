## REMOVED Requirements

### Requirement: This repository is the sole source of the demo's dashboards

**Reason**: The demo provisions no dashboards. Grafana is removed together with the panel
plugin it existed to carry, so there is no dashboard whose source of truth needs
defending.

**Migration**: The equivalent claim for the standalone front door is
`frontend-provisioning` → "This repository owns the frontend's runtime configuration",
which requires the same thing of the file the frontend actually reads: it is tracked
here, no bring-up step replaces it from another repository, and an edit survives the next
bring-up.

### Requirement: Replacing tracked dashboards from the panel repository is not a routine operation

**Reason**: The panel repository is no longer a submodule of this demo, and no dashboard
exists to overwrite. The copy path this requirement guarded against was retired before
this change and its subject is now gone entirely.

**Migration**: None needed. `frontend-provisioning` → "Bring-up needs no panel
repository" asserts the stronger property: no step of bringing the demo up reads a panel
plugin source tree at all.

### Requirement: Provisioned dashboards call only endpoints the backend serves

**Reason**: There is no provisioned dashboard to walk. The failure this guarded — a
front-end request against an endpoint the pinned backend no longer serves, which fails
quietly while the graph keeps drawing — is unchanged, but its subject is now the
frontend's own requests.

**Migration**: `frontend-provisioning` → "The pipeline walk covers the front door"
requires the verification walk to assert that the graph endpoint the served configuration
names answers through the frontend's origin, which is the same assertion against the new
front door.

### Requirement: A control that cannot change the graph is not shipped

**Reason**: The requirement is retained verbatim in substance, but its subject moves from
a Grafana dashboard control to a control in the standalone frontend.

**Migration**: `frontend-graph-controls` → "The front door exposes the backend's filter
dimensions" carries it, including the scenario that no control sends a parameter the
pinned backend has withdrawn.

### Requirement: Cluster, availability-zone, environment and namespace filters come from the pod inventory

**Reason**: Same substance, different front end. Grafana template variables querying a
provisioned datasource no longer exist; the frontend reads the same label values itself.

**Migration**: `frontend-graph-controls` → "Identity filter options come from the pod
inventory" keeps every claim, including the raw-name-versus-composed-identity rule, the
requirement that all three identity components are sent together, and the note that
options track the inventory rather than the projection.

### Requirement: The dashboard exposes the backend's projection choice

**Reason**: Same substance, different front end.

**Migration**: `frontend-graph-controls` → "The projection control defaults to the
traffic graph". The scenario about option lists following the selected projection is
dropped rather than migrated: it existed because Grafana repopulated one variable from
the graph endpoint under whatever projection was selected, and the frontend populates no
control from the graph endpoint.

### Requirement: Provisioned dashboards describe only what the demo runs

**Reason**: No dashboard is provisioned, so no dashboard text can describe another
repository's development setup.

**Migration**: `frontend-provisioning` → "The front door renders live data, never the
bundled fixture" covers the surviving concern: the frontend ships a showcase fixture for
its own development, and the demo's provisioned configuration must disable it.

### Requirement: The demo provisions a dashboard backed by the running backend

**Reason**: The demo provisions a frontend, not a dashboard.

**Migration**: `frontend-provisioning` → "The demo's front door is the standalone
frontend" and "The front door renders live data, never the bundled fixture" together
carry the claim that what a viewer sees is produced by the running backend from real
pipeline data.
