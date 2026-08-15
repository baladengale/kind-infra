# kind-infra — local Kubernetes base infrastructure via make
#
#   make create    cluster + local registry + AgentGateway + DNS
#   make update    re-apply addons on the existing cluster (idempotent)
#   make upgrade   recreate the cluster with a newer Kubernetes version
#   make delete    remove DNS entries, cluster and registry
#   make status    show what is running and whether DNS works
#
# Override any variable on the command line, e.g.:
#   make create DOMAIN=acme.test KIND_IMAGE_VERSION=1.36.0

DOMAIN              ?= internal
KIND_CLUSTER_NAME   ?= kind
KIND_IMAGE_VERSION  ?= 1.35.0
GWAPI_VERSION       ?= 1.6.0
AGW_VERSION         ?= 0.0.0-latest-dev
CONTAINER_RUNTIME   ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)

export DOMAIN KIND_CLUSTER_NAME KIND_IMAGE_VERSION GWAPI_VERSION AGW_VERSION CONTAINER_RUNTIME

KUBE_CONTEXT := kind-$(KIND_CLUSTER_NAME)
HOST ?=
NS   ?= default
SVC  ?=
PORT ?=

.DEFAULT_GOAL := help
.PHONY: help create update upgrade delete delete-cluster dns-install dns-remove \
        expose unexpose sync status kubectl-tools

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

create: ## Create everything: cluster, registry, AgentGateway
	@bash scripts/10-create-cluster.sh
	@bash scripts/30-gateway.sh
	@bash scripts/50-registry.sh
	@echo ""
	@echo "Base infra ready. Register any app with:"
	@echo "  make expose HOST=myapp NS=<ns> SVC=<service> PORT=<port>"
	@echo "  -> https://myapp.$(DOMAIN)"

update: ## Re-apply addons on the existing cluster (picks up version bumps)
	@bash scripts/30-gateway.sh
	@bash scripts/50-registry.sh
	@echo "Update complete."

upgrade: ## Recreate the cluster with the current KIND_IMAGE_VERSION (destructive)
	@read -p "Recreate cluster '$(KIND_CLUSTER_NAME)' with kindest/node:v$(KIND_IMAGE_VERSION)? Workloads are lost. [y/N] " ans; \
		[ "$$ans" = "y" ] || { echo "Aborted."; exit 1; }
	@$(MAKE) --no-print-directory delete
	@$(MAKE) --no-print-directory create

delete: ## Remove entries, delete the cluster and the registry
	@$(MAKE) --no-print-directory delete-cluster
	@if [ "$$($(CONTAINER_RUNTIME) ps -aq --filter name=^kind-registry$$)" != "" ]; then \
		echo "Removing kind-registry container..."; \
		$(CONTAINER_RUNTIME) rm -f kind-registry; \
	fi
	@echo "Teardown complete."

delete-cluster: ## Delete only the kind cluster (registry untouched)
	@kind delete cluster --name $(KIND_CLUSTER_NAME)

dns-install: ## Install/refresh the local DNS zone (*.$(DOMAIN))
	@bash scripts/40-dns-install.sh

dns-remove: ## Remove the local DNS zone (*.$(DOMAIN))
	@bash scripts/41-dns-remove.sh

expose: ## Route HOST.$(DOMAIN) to a Service: make expose HOST=x NS=y SVC=z PORT=n
	@if [ -z "$(HOST)" ] || [ -z "$(SVC)" ]; then \
		echo "usage: make expose HOST=kagent NS=kagent SVC=kagent-ui PORT=8080"; exit 2; fi
	@bash scripts/60-register.sh expose "$(HOST)" "$(NS)" "$(SVC)" "$(PORT)"

unexpose: ## Remove a registration: make unexpose HOST=kagent
	@if [ -z "$(HOST)" ]; then \
		echo "usage: make unexpose HOST=kagent"; exit 2; fi
	@bash scripts/60-register.sh remove "$(HOST)"

sync: ## Sync annotated Services (kind-infra.dev/host) to HTTPS hostnames (+ prune)
	@bash scripts/60-register.sh sync

status: ## Show clusters, addons, registry and DNS state
	@echo "== clusters =="; kind get clusters 2>/dev/null || echo "(none)"
	@echo "== nodes =="; \
		kubectl --context $(KUBE_CONTEXT) get nodes 2>/dev/null || echo "(no cluster '$(KIND_CLUSTER_NAME)')"
	@echo "== agentgateway =="; \
		kubectl --context $(KUBE_CONTEXT) get pods -n agentgateway-system 2>/dev/null || true
	@echo "== gateway =="; \
		kubectl --context $(KUBE_CONTEXT) get gateway -n agentgateway-system 2>/dev/null || true
	@echo "== registry =="; \
		$(CONTAINER_RUNTIME) ps --filter name=kind-registry --format '{{.Names}}  {{.Status}}' 2>/dev/null || echo "(not running)"
	@echo "== dns (dig test.$(DOMAIN) @127.0.0.1) =="; \
		dig +short test.$(DOMAIN) @127.0.0.1 2>/dev/null || echo "(dnsmasq not answering)"
	@echo "== gateway probe (https://test.$(DOMAIN)) =="; \
		curl -sk -o /dev/null -w 'HTTP %{http_code}\n' --max-time 3 https://test.$(DOMAIN) 2>/dev/null || echo "(no response)"

kubectl-tools: ## Install kubectl plugins (kubecolor, kctx, kns)
	@bash scripts/kubectl-tools.sh
