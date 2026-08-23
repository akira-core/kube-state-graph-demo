# pod-application-grouping Specification

## Purpose
Defines how a pod in the demo acquires the ArgoCD Application it belongs to, so that the
graph can nest pods under an application group the way it already nests services and
claims, and defines how the graph behaves for pods that have no Application.

## Requirements

### Requirement: Demo workload pods declare the Application that owns them

Every pod the demo deploys as part of a named application SHALL carry, on the pod
itself, an identifier naming that application. The identifier SHALL be carried the way a
GitOps controller stamps the resources it manages, so the demo exercises the same path a
production cluster would, rather than a demo-only convention.

#### Scenario: A running workload pod names its application

- **WHEN** any demo workload pod is inspected
- **THEN** it carries an identifier naming the application it belongs to
- **AND** that identifier matches the application the same workload's Service and claims
  already declare

### Requirement: The pod-to-Application association is published as a metric

The metrics pipeline SHALL publish `kube_pod_owner` series carrying a non-empty
`argocd_tracking_id` label for every pod that declares an application. This is the only
source the graph reads for a pod's Application, so the association SHALL be observable
in the metric store rather than resolved at graph-build time from any other input.

#### Scenario: Tracking id is queryable for demo pods

- **WHEN** the metric store is queried for `kube_pod_owner` restricted to a non-empty
  `argocd_tracking_id`
- **THEN** series are returned for the demo's application-owning pods
- **AND** each series identifies its pod by cluster, namespace and pod name

#### Scenario: The published value resolves to the intended application name

- **WHEN** the graph resolves a pod's Application from the published tracking id
- **THEN** the resulting Application name equals the application that pod declares

### Requirement: Publishing the association does not disturb controller resolution

Republishing `kube_pod_owner` with an added label SHALL NOT change how the graph
resolves a pod's controller. Each pod SHALL still resolve to exactly one controller, and
the graph's node and edge sets SHALL be unchanged except for the addition of application
grouping.

#### Scenario: Each pod still resolves to one controller

- **WHEN** the graph is built after the association is published
- **THEN** every pod node carries exactly one owner
- **AND** no pod appears more than once in the graph

#### Scenario: Edge sets are unaffected

- **WHEN** the graph is built after the association is published
- **THEN** the set of edges is the same as before the association existed

### Requirement: Pods nest under their Application

A pod that has an Application SHALL be grouped under that Application in the graph, so
the nesting reads cluster, then namespace, then application, then controller, then pod.

#### Scenario: An application group appears for a demo application

- **WHEN** the graph is built
- **THEN** an application group node exists for each of the demo's applications
- **AND** the pods declaring that application are nested inside it

### Requirement: A pod without an Application degrades rather than fails

A pod carrying no application identifier SHALL still appear in the graph, nested under
its controller with no application level, and SHALL carry no application attribute. Its
absence SHALL NOT produce an error, a warning that reads as a fault, or an empty graph.

#### Scenario: An application-less pod is still graphed

- **WHEN** a pod carries no application identifier and the graph is built
- **THEN** that pod appears in the graph nested directly under its controller
- **AND** the graph build succeeds with no error attributable to the missing identifier

### Requirement: Claims inherit an Application from the pods that mount them

A claim that declares no Application of its own SHALL take one from the pods that mount
it, so that a claim reachable only through its mounting workload is still grouped.

#### Scenario: An application-less claim borrows from its mounting pod

- **WHEN** a claim declares no Application and is mounted by a pod that declares one
- **THEN** the claim is grouped under the mounting pod's Application
