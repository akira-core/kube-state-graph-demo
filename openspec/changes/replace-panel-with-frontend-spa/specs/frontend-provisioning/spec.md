## Purpose

Defines how the demo stands up the standalone kube-state-graph frontend as its front
door: where the image comes from, who owns the runtime configuration the browser reads,
how the browser reaches the backend and the metric store without holding a credential,
and what has to be true before bring-up claims the demo is ready.

## ADDED Requirements

### Requirement: The demo's front door is the standalone frontend

The demo SHALL serve its graph user interface from the `kube-state-graph-frontend`
submodule, deployed into the cluster from an image built out of that submodule. No
Grafana instance, panel plugin, dashboard definition or datasource SHALL be provisioned
in order to draw the graph.

The entry point SHALL remain the host port the demo has always published its front door
on, so the documented address does not move; what answers on it changes, and every
document naming that address SHALL name the frontend.

#### Scenario: The published entry point serves the application

- **WHEN** the demo's front-door host port is opened after bring-up
- **THEN** the standalone frontend application is served
- **AND** no Grafana login, dashboard list or panel chrome is served

#### Scenario: No Grafana workload is installed

- **WHEN** the installed release's workloads are listed
- **THEN** none of them is Grafana
- **AND** no dashboard definition or datasource file is provisioned by the release

#### Scenario: Bring-up needs no panel repository

- **WHEN** the demo is brought up on a clean checkout
- **THEN** no step reads from a Grafana panel plugin source tree
- **AND** no image is built to carry a plugin directory into another pod

### Requirement: The frontend image is built from the pinned submodule

The frontend image SHALL be built from the submodule's own tracked source and
side-loaded into the cluster like every other first-party image, so a bring-up pulls
nothing for it. An override SHALL exist to build the image from a working copy outside
this repository, matching the override the other first-party components already offer,
so an unpushed frontend change can be demonstrated without moving the submodule pointer.

A rebuilt image SHALL NOT be considered live until it has been re-loaded into the cluster
and the frontend workload has been rolled out; a single command SHALL perform all three.

#### Scenario: The image is side-loaded, never pulled

- **WHEN** the frontend workload starts
- **THEN** it runs the locally built image
- **AND** the cluster attempts no registry pull for it

#### Scenario: An outside working copy can be demonstrated

- **WHEN** bring-up is asked to build the frontend from a working copy outside this
  repository
- **THEN** the deployed frontend is built from that working copy
- **AND** the submodule pointer is unchanged

#### Scenario: One command makes a rebuild live

- **WHEN** the frontend redeploy command is run after a source change
- **THEN** the image is rebuilt, re-loaded into the cluster, and the workload rolled out
- **AND** the served application reflects the change

### Requirement: This repository owns the frontend's runtime configuration

The frontend reads its configuration from a file served at its own origin on every full
page load. That file SHALL be provisioned by this repository as tracked source and
mounted into the frontend, so the demo — not the frontend repository's development
default — decides what the deployed application talks to.

The provisioned configuration SHALL disable the frontend's built-in demo fixture. A demo
whose front door renders a bundled fixture proves nothing about the pipeline behind it,
and is indistinguishable to a viewer from a working one.

#### Scenario: The served configuration is the one this repository tracks

- **WHEN** the configuration file is requested from the running frontend
- **THEN** it is valid JSON
- **AND** its content matches the configuration this repository provisions

#### Scenario: The front door renders live data, never the bundled fixture

- **WHEN** the frontend loads against a healthy demo
- **THEN** it renders the topology returned by the running backend
- **AND** it does not render the frontend's built-in showcase fixture

#### Scenario: A configuration edit survives bring-up

- **WHEN** the provisioned configuration is edited in this repository and the demo is
  brought up again
- **THEN** the served configuration reflects the edit

### Requirement: The browser reaches the backend and the metric store same-origin

Every request the frontend makes on behalf of the demo SHALL be addressed to the
frontend's own origin and forwarded in-cluster. Two destinations SHALL be reachable this
way: the graph API, and the label-values API of the metric store that holds the pod
inventory.

This is not decoration. Absolute cross-origin URLs would require the backend to permit
the frontend's origin, and would put the metric store's credential in a place the browser
can read it.

#### Scenario: Graph requests are same-origin

- **WHEN** the frontend requests the graph
- **THEN** the request is addressed to the frontend's own origin
- **AND** it is answered by the running backend

#### Scenario: Label-value requests are same-origin

- **WHEN** the frontend requests label values for a filter control
- **THEN** the request is addressed to the frontend's own origin
- **AND** it is answered by the store holding the pod inventory

#### Scenario: No cross-origin failure is possible for either destination

- **WHEN** the frontend's requests are inspected
- **THEN** none of them names a host other than the frontend's own origin

### Requirement: The metric store credential never reaches the browser

The pod-inventory store's read path is behind basic authentication. The credential SHALL
be attached to the forwarded request inside the cluster and SHALL NOT be present in
anything the browser receives — not in the served configuration, not in application code,
and not in a response header.

The credential SHALL be the same one every other component of the demo reads, held once
and distributed from there, so a rotation cannot leave one consumer behind.

#### Scenario: The served configuration carries no credential

- **WHEN** the frontend's configuration file is fetched
- **THEN** it contains no username, password or authorization value

#### Scenario: An unauthenticated browser request still resolves

- **WHEN** the frontend requests label values without sending credentials
- **THEN** the request succeeds
- **AND** the credential was supplied in-cluster, not by the browser

#### Scenario: One credential, one source

- **WHEN** the demo's basic-auth credential is changed in the one place it is declared
- **THEN** the frontend's forwarded requests use the new value
- **AND** no other copy of the old value remains in the release

### Requirement: Bring-up waits for the front door to answer

Bring-up SHALL NOT report the demo ready until the frontend answers its own health
endpoint, in addition to the storage-chain signals it already waits for. A front door
that is scheduled but not serving turns the first thing a viewer does into a failure.

The health check SHALL be the frontend's own liveness path, which does not depend on the
configuration file or on the backend, so it reports the server's readiness rather than
the pipeline's.

#### Scenario: Bring-up blocks on the front door

- **WHEN** bring-up completes
- **THEN** the frontend has answered its health endpoint successfully

#### Scenario: Health does not depend on the pipeline

- **WHEN** the backend is unavailable
- **THEN** the frontend's health endpoint still answers successfully

### Requirement: The pipeline walk covers the front door

The demo's verification walk SHALL assert the front door alongside the pipeline hops it
already covers: that the frontend serves its configuration, that the graph endpoint that
configuration names answers through the frontend's origin, and that the label-values
path answers through it too.

A front door that draws nothing while every upstream hop is green is precisely the
failure this walk exists to name, so its absence from the walk SHALL be treated as a gap
in the walk.

#### Scenario: The walk names the front door

- **WHEN** the verification walk is run against a healthy demo
- **THEN** it reports a check for the served configuration
- **AND** a check for the graph endpoint answering through the frontend
- **AND** a check for the label-values path answering through the frontend

#### Scenario: A broken front door fails the walk

- **WHEN** the frontend's configuration is absent or its proxies do not resolve
- **THEN** the verification walk fails and names which of the three is missing
