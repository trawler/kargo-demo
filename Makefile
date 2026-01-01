.PHONY: help setup-kind deploy destroy clean status port-forward

# Default target
help:
	@echo "Available targets:"
	@echo "  make setup-kind      - Create all kind clusters"
	@echo "  make deploy          - Deploy applicationsets to clusters"
	@echo "  make destroy         - Destroy all kind clusters"
	@echo "  make clean           - Remove deployments and return clusters to clean state"
	@echo "  make status          - Show cluster and application status"
	@echo "  make port-forward    - Port-forward ArgoCD servers"
	@echo ""
	@echo "Combined targets:"
	@echo "  make all             - Run setup-kind and deploy"
	@echo "  make reset            - Run destroy and then setup-kind"

# Scripts directory
SCRIPTS_DIR := scripts

# Use Homebrew bash if available, otherwise fall back to system bash
BASH := $(shell which /opt/homebrew/bin/bash 2>/dev/null || which bash)

# Create kind clusters
setup-kind:
	@echo "Creating kind clusters..."
	@$(BASH) $(SCRIPTS_DIR)/setup-kind.sh

# Deploy applicationsets
deploy:
	@echo "Deploying applicationsets..."
	@$(BASH) $(SCRIPTS_DIR)/deploy-applicationsets.sh

# Destroy kind clusters
destroy:
	@echo "Destroying kind clusters..."
	@$(BASH) $(SCRIPTS_DIR)/destroy-kind.sh

# Clean deployments but keep clusters
clean:
	@echo "Cleaning deployments from clusters..."
	@$(BASH) $(SCRIPTS_DIR)/clean-deployments.sh

# Combined targets
all: setup-kind deploy

reset: destroy setup-kind

# Show status
status:
	@echo "=== Cluster Status ==="
	@echo ""
	@echo "Stage Control:"
	@kubectl --context kind-stage-control cluster-info 2>/dev/null && echo "  ✓ Running" || echo "  ✗ Not found"
	@echo ""
	@echo "Stage Workload:"
	@kubectl --context kind-stage-workload cluster-info 2>/dev/null && echo "  ✓ Running" || echo "  ✗ Not found"
	@echo ""
	@echo "Prod Control:"
	@kubectl --context kind-prod-control cluster-info 2>/dev/null && echo "  ✓ Running" || echo "  ✗ Not found"
	@echo ""
	@echo "Prod Workload:"
	@kubectl --context kind-prod-workload cluster-info 2>/dev/null && echo "  ✓ Running" || echo "  ✗ Not found"
	@echo ""
	@echo "=== ArgoCD AppProjects (Stage) ==="
	@kubectl --context kind-stage-control get appproject -n argocd 2>/dev/null || echo "  Not deployed"
	@echo ""
	@echo "=== ArgoCD AppProjects (Prod) ==="
	@kubectl --context kind-prod-control get appproject -n argocd 2>/dev/null || echo "  Not deployed"
	@echo ""
	@echo "=== ArgoCD Applicationsets (Stage) ==="
	@kubectl --context kind-stage-control get applicationsets -n argocd 2>/dev/null || echo "  Not deployed"
	@echo ""
	@echo "=== ArgoCD Applicationsets (Prod) ==="
	@kubectl --context kind-prod-control get applicationsets -n argocd 2>/dev/null || echo "  Not deployed"

# Port-forward ArgoCD servers
port-forward:
	@echo "Starting port-forwards for ArgoCD servers..."
	@echo "Stage Control ArgoCD: http://localhost:8080"
	@echo "Prod Control ArgoCD: http://localhost:8081"
	@echo ""
	@echo "Press Ctrl+C to stop"
	@kubectl --context kind-stage-control port-forward -n argocd svc/argocd-server 8080:443 --address=127.0.0.1 & \
	kubectl --context kind-prod-control port-forward -n argocd svc/argocd-server 8081:443 --address=127.0.0.1 & \
	wait

