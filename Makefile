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
BACKEND_SRC  ?= kube-state-graph
PANEL_SRC    ?= kube-state-graph-panel

BACKEND_IMAGE ?= ksg-demo/kube-state-graph:local
PANEL_IMAGE   ?= ksg-demo/panel:local
TOOLS_IMAGE   ?= ksg-demo/tools:local

# Host ports, as mapped in kind/cluster.yaml.
GRAFANA_URL  := http://localhost:3001
BACKEND_URL  := http://localhost:18080
VMSELECT_URL := http://localhost:18481/select/0/prometheus

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nkube-state-graph demo\n\nUsage: make <target>\n\n"} \
	     /^[a-zA-Z0-9_.-]+:.*##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
	     /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo

##@ Whole demo

.PHONY: up
up: submodules cluster images load sync-dashboards deps install wait ## Build and run the entire demo from scratch
	@$(MAKE) --no-print-directory urls

.PHONY: down
down: ## Delete the kind cluster and everything in it
	kind delete cluster --name $(CLUSTER)

.PHONY: urls
urls: ## Print the demo's entry points
	@echo
	@echo "  Grafana         $(GRAFANA_URL)      (anonymous admin; dashboard: kube-state-graph / KSG Demo)"
	@echo "  Graph API       $(BACKEND_URL)/docs"
	@echo "  VictoriaMetrics $(VMSELECT_URL)"
	@echo

##@ Pieces

.PHONY: submodules
submodules: ## Check out the kube-state-graph and panel submodules
	git submodule update --init --recursive

.PHONY: cluster
cluster: ## Create the kind cluster (no-op if it already exists)
	@if kind get clusters 2>/dev/null | grep -qx '$(CLUSTER)'; then \
	  echo "kind cluster $(CLUSTER) already exists"; \
	else \
	  kind create cluster --config kind/cluster.yaml; \
	fi

.PHONY: images
images: image-backend image-panel image-tools ## Build all three local images

.PHONY: image-backend
image-backend: ## Build the kube-state-graph API server image
	docker build -f docker/backend.Dockerfile -t $(BACKEND_IMAGE) $(BACKEND_SRC)

.PHONY: image-panel
image-panel: ## Build the Grafana panel plugin image (npm build runs inside)
	docker build -f docker/panel.Dockerfile -t $(PANEL_IMAGE) $(PANEL_SRC)

.PHONY: image-tools
image-tools: ## Build the demo workload + netapp-faker image
	docker build -f docker/tools.Dockerfile -t $(TOOLS_IMAGE) tools

.PHONY: load
load: ## Side-load the local images into the kind nodes
	kind load docker-image --name $(CLUSTER) $(BACKEND_IMAGE) $(PANEL_IMAGE) $(TOOLS_IMAGE)

.PHONY: sync-dashboards
sync-dashboards: ## Copy the panel repo's dashboards into the umbrella chart
	./scripts/sync-dashboards.sh

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
	./scripts/wait-ready.sh $(KUBECTX) $(NAMESPACE) $(BACKEND_URL)

##@ Iterating

.PHONY: redeploy-backend
redeploy-backend: image-backend ## Rebuild the backend image and restart its pod
	kind load docker-image --name $(CLUSTER) $(BACKEND_IMAGE)
	$(KUBECTL) -n $(NAMESPACE) rollout restart deployment/kube-state-graph
	$(KUBECTL) -n $(NAMESPACE) rollout status deployment/kube-state-graph

.PHONY: redeploy-panel
redeploy-panel: image-panel ## Rebuild the panel plugin and restart Grafana
	kind load docker-image --name $(CLUSTER) $(PANEL_IMAGE)
	$(KUBECTL) -n $(NAMESPACE) rollout restart deployment/grafana
	$(KUBECTL) -n $(NAMESPACE) rollout status deployment/grafana

.PHONY: redeploy-workloads
redeploy-workloads: image-tools ## Rebuild the demo app and restart every workload
	kind load docker-image --name $(CLUSTER) $(TOOLS_IMAGE)
	$(KUBECTL) -n shop rollout restart deployment,statefulset
	$(KUBECTL) -n platform rollout restart deployment,statefulset
	$(KUBECTL) -n $(NAMESPACE) rollout restart deployment/$(RELEASE)-netapp-faker

##@ Inspecting

.PHONY: verify
verify: ## Check every hop of the pipeline and report what the graph contains
	./scripts/verify.sh $(VMSELECT_URL) $(BACKEND_URL)

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
	$(HELM) lint charts/netapp-faker --set vmSelectURL=http://x --set vmInsertURL=http://x
	$(HELM) lint charts/demo-workloads --set otlpEndpoint=http://x:4317
	$(HELM) lint charts/ksg-demo

.PHONY: template
template: ## Render the umbrella chart without installing it
	$(HELM) template $(RELEASE) charts/ksg-demo --namespace $(NAMESPACE)

.PHONY: vendor-charts
vendor-charts: ## Re-fetch the vendored upstream subcharts (NEEDS NETWORK; commit the result)
	./scripts/vendor-charts.sh
