SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Everything the demo is named after. The release name is NOT baked into the
# in-cluster URLs (the charts pin those with fullnameOverride), so changing it
# here is safe; changing CLUSTER means re-creating the kind cluster.
# ---------------------------------------------------------------------------
CLUSTER      ?= ksg-demo
RELEASE      ?= ksg-demo
NAMESPACE    ?= monitoring
KUBECTX      := kind-$(CLUSTER)
KUBECTL      := kubectl --context $(KUBECTX)
HELM         := helm --kube-context $(KUBECTX)

# Source of the two first-party components. Point these at your own working
# copies to demo an unpushed change:
#   make images BACKEND_SRC=../kube-state-graph
#   make redeploy-frontend FRONTEND_SRC=../kube-state-graph-frontend
BACKEND_SRC  ?= kube-state-graph
FRONTEND_SRC ?= kube-state-graph-frontend

BACKEND_IMAGE  ?= ksg-demo/kube-state-graph:local
FRONTEND_IMAGE ?= ksg-demo/kube-state-graph-frontend:local
TOOLS_IMAGE    ?= ksg-demo/tools:local

# Host ports, as mapped in kind/cluster.yaml. TWO stores: the graph is assembled
# from both and the routing table in charts/ksg-demo/values.yaml decides which
# query families go where.
FRONTEND_URL := http://localhost:3001
BACKEND_URL  := http://localhost:18080
# Cluster store — NetApp Harvest and service-graph series.
VMSELECT_URL := http://localhost:18481/select/0/prometheus
# Single-node store, through vmauth — kube-state-metrics and kubelet series.
VMAUTH_URL   := http://localhost:18427
VMAUTH_USER  ?= ksg
VMAUTH_PASS  ?= ksg-demo-not-a-real-secret

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nkube-state-graph demo\n\nUsage: make <target>\n\n"} \
	     /^[a-zA-Z0-9_.-]+:.*##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
	     /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo

##@ Whole demo

.PHONY: up
up: submodules cluster images load deps install wait ## Build and run the entire demo from scratch
	@$(MAKE) --no-print-directory urls

.PHONY: down
down: ## Delete the kind cluster and everything in it
	kind delete cluster --name $(CLUSTER)

.PHONY: urls
urls: ## Print the demo's entry points
	@echo
	@echo "  Front door      $(FRONTEND_URL)      (the standalone SPA; graph + sankey)"
	@echo "  Graph API       $(BACKEND_URL)/docs"
	@echo "  VM cluster      $(VMSELECT_URL)   (harvest, service-graph; ad-hoc PromQL)"
	@echo "  VM single       $(VMAUTH_URL)   (kube-state-metrics, kubelet; -u $(VMAUTH_USER):...)"
	@echo

##@ Pieces

.PHONY: submodules
submodules: ## Check out the kube-state-graph and frontend submodules
	git submodule update --init --recursive

.PHONY: cluster
cluster: ## Create the kind cluster (no-op if it already exists)
	@if kind get clusters 2>/dev/null | grep -qx '$(CLUSTER)'; then \
	  echo "kind cluster $(CLUSTER) already exists"; \
	else \
	  kind create cluster --config kind/cluster.yaml; \
	fi

.PHONY: images
images: image-backend image-frontend image-tools ## Build all three local images

.PHONY: image-backend
image-backend: ## Build the kube-state-graph API server image
	docker build -f docker/backend.Dockerfile -t $(BACKEND_IMAGE) $(BACKEND_SRC)

# Built from the SUBMODULE's own Dockerfile, unlike the backend. It ships a
# complete multi-stage build producing an nginx server, so there is nothing for
# this repository to write. docker/panel.Dockerfile existed only because a
# Grafana plugin is not a server: that image was a file carrier.
.PHONY: image-frontend
image-frontend: ## Build the front-door SPA image (npm build runs inside)
	docker build -f $(FRONTEND_SRC)/Dockerfile -t $(FRONTEND_IMAGE) $(FRONTEND_SRC)

.PHONY: image-tools
image-tools: ## Build the demo workload + netapp-faker image
	docker build -f docker/tools.Dockerfile -t $(TOOLS_IMAGE) tools

.PHONY: load
load: ## Side-load the local images into the kind nodes
	kind load docker-image --name $(CLUSTER) $(BACKEND_IMAGE) $(FRONTEND_IMAGE) $(TOOLS_IMAGE)

.PHONY: deps
deps: ## Package the local subcharts and verify the vendored upstream ones (offline)
	./scripts/charts-deps.sh

.PHONY: install
install: ## Install or upgrade the ksg-demo release
	$(HELM) upgrade --install $(RELEASE) charts/ksg-demo \
	    --namespace $(NAMESPACE) --create-namespace \
	    --timeout 10m

.PHONY: wait
wait: ## Block until every demo workload is ready
	./scripts/wait-ready.sh $(KUBECTX) $(NAMESPACE) $(BACKEND_URL) $(FRONTEND_URL)

##@ Iterating

.PHONY: redeploy-backend
redeploy-backend: image-backend ## Rebuild the backend image and restart its pod
	kind load docker-image --name $(CLUSTER) $(BACKEND_IMAGE)
	$(KUBECTL) -n $(NAMESPACE) rollout restart deployment/kube-state-graph
	$(KUBECTL) -n $(NAMESPACE) rollout status deployment/kube-state-graph

.PHONY: redeploy-frontend
redeploy-frontend: image-frontend ## Rebuild the front-door SPA and restart it
	kind load docker-image --name $(CLUSTER) $(FRONTEND_IMAGE)
	$(KUBECTL) -n $(NAMESPACE) rollout restart deployment/kube-state-graph-frontend
	$(KUBECTL) -n $(NAMESPACE) rollout status deployment/kube-state-graph-frontend

.PHONY: redeploy-workloads
redeploy-workloads: image-tools ## Rebuild the demo app and restart every workload
	kind load docker-image --name $(CLUSTER) $(TOOLS_IMAGE)
	$(KUBECTL) -n shop rollout restart deployment,statefulset
	$(KUBECTL) -n platform rollout restart deployment,statefulset
	$(KUBECTL) -n $(NAMESPACE) rollout restart deployment/$(RELEASE)-netapp-faker

##@ Inspecting

.PHONY: verify
verify: ## Check every hop of the pipeline and report what the graph contains
	./scripts/verify.sh $(VMSELECT_URL) $(BACKEND_URL) $(VMAUTH_URL) $(VMAUTH_USER) $(VMAUTH_PASS) $(FRONTEND_URL)

.PHONY: status
status: ## Show pods across every demo namespace
	$(KUBECTL) get pods -n $(NAMESPACE) -o wide
	$(KUBECTL) get pods -n shop -o wide
	$(KUBECTL) get pods -n platform -o wide
	$(KUBECTL) get pvc -A

.PHONY: graph
graph: ## Fetch the last 5 minutes of graph JSON from the API
	@curl -sS "$(BACKEND_URL)/v1/graph?start=$$(($$(date +%s) - 300))&end=$$(date +%s)" | jq .

.PHONY: logs-backend
logs-backend: ## Tail the kube-state-graph server log
	$(KUBECTL) -n $(NAMESPACE) logs -f deployment/kube-state-graph

.PHONY: logs-collector
logs-collector: ## Tail the OpenTelemetry Collector log
	$(KUBECTL) -n $(NAMESPACE) logs -f deployment/otel-collector

.PHONY: logs-faker
logs-faker: ## Tail the netapp-faker log
	$(KUBECTL) -n $(NAMESPACE) logs -f deployment/$(RELEASE)-netapp-faker

##@ Development

.PHONY: lint
lint: ## Vet the Go tools and lint every chart
	cd tools && gofmt -l . && go vet ./...
	$(HELM) lint charts/kube-state-graph --set promURL=http://x
	$(HELM) lint charts/kube-state-graph-frontend --set global.ksgUpstreamAuth.username=x --set global.ksgUpstreamAuth.password=x
	$(HELM) lint charts/netapp-faker --set vmSelectURL=http://x --set vmInsertURL=http://x
	$(HELM) lint charts/demo-workloads --set otlpEndpoint=http://x:4317
	$(HELM) lint charts/nfs-server
	$(HELM) lint charts/ksg-demo

.PHONY: template
template: ## Render the umbrella chart without installing it
	$(HELM) template $(RELEASE) charts/ksg-demo --namespace $(NAMESPACE)

.PHONY: vendor-charts
vendor-charts: ## Re-fetch the vendored upstream subcharts (NEEDS NETWORK; commit the result)
	./scripts/vendor-charts.sh
