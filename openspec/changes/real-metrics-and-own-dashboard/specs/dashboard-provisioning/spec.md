## Purpose

Defines which dashboards the demo provisions, that this repository is their source of
truth rather than a copy target, and that pulling a dashboard in from the panel
repository is a deliberate operator action instead of a step in bringing the demo up.

## ADDED Requirements

### Requirement: This repository is the source of truth for provisioned dashboards

The dashboards the demo provisions SHALL be tracked source files in this repository. No
step of bringing the demo up SHALL overwrite them from another repository, so an edit
made here survives the next bring-up.

#### Scenario: An edited dashboard survives bring-up

- **WHEN** a provisioned dashboard is edited in this repository and the demo is brought
  up again
- **THEN** the deployed dashboard reflects the edit

#### Scenario: Bring-up requires no other repository for dashboards

- **WHEN** the demo is brought up with the panel repository's working tree absent or
  empty
- **THEN** bring-up still provisions the demo's dashboards
- **AND** bring-up does not fail for want of a dashboard source

### Requirement: Importing from the panel repository is an explicit action

Pulling a dashboard in from the panel repository SHALL remain available as an operator
action invoked on purpose. It SHALL NOT run as part of bringing the demo up, and it
SHALL make clear that it overwrites this repository's tracked dashboards.

#### Scenario: Import is available on demand

- **WHEN** an operator invokes the import action
- **THEN** the panel repository's dashboards replace this repository's dashboard sources
- **AND** the replaced files are reported so the operator can review or revert them

#### Scenario: Import does not run during bring-up

- **WHEN** the demo is brought up
- **THEN** the import action does not run

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
in its own definition SHALL NOT be provisioned by default, because a deployment that has
a working backend has no need to demonstrate one that does not.

#### Scenario: The provisioned dashboard reads from the backend

- **WHEN** the provisioned dashboard loads against a healthy demo
- **THEN** it renders the topology returned by the running backend
- **AND** the rendered content changes when the underlying cluster changes

#### Scenario: No backend-free fixture dashboard is provisioned

- **WHEN** the provisioned dashboards are listed
- **THEN** none of them renders from a fixture embedded in the dashboard definition
