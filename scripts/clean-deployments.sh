#!/bin/bash
set -e

echo "Cleaning deployments from kind clusters..."

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() {
    echo -e "${GREEN}ℹ${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Clean ArgoCD deployments from a cluster
clean_cluster() {
    local cluster=$1
    
    if ! kubectl --context kind-"$cluster" cluster-info &>/dev/null; then
        echo_warn "Cluster $cluster does not exist, skipping..."
        return
    fi
    
    echo_info "Cleaning $cluster..."
    
    # Delete all ApplicationSets first (they create Applications)
    echo_info "  Deleting ApplicationSets..."
    kubectl --context kind-"$cluster" delete applicationsets --all -n argocd --ignore-not-found=true --timeout=30s 2>/dev/null || true
    
    # Delete all Applications
    echo_info "  Deleting Applications..."
    kubectl --context kind-"$cluster" delete applications --all -n argocd --ignore-not-found=true --timeout=30s 2>/dev/null || true
    
    # Remove finalizers from Applications (ArgoCD controller may be gone, causing deadlock)
    echo_info "  Removing finalizers from Applications..."
    local apps
    apps=$(kubectl --context kind-"$cluster" get applications -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$apps" ]; then
        for app in $apps; do
            kubectl --context kind-"$cluster" patch application "$app" -n argocd \
                --type json \
                -p='[{"op": "remove", "path": "/metadata/finalizers"}]' \
                2>/dev/null || true
        done
    fi
    
    # Wait a moment for Applications to be fully deleted
    sleep 3
    
    # Delete AppProjects (except default)
    echo_info "  Deleting AppProjects..."
    kubectl --context kind-"$cluster" delete appproject msvc-system -n argocd --ignore-not-found=true --timeout=30s 2>/dev/null || true
    
    # Unregister workload clusters (delete cluster secrets)
    if [ "$cluster" = "stage-control" ]; then
        echo_info "  Unregistering workload clusters..."
        kubectl --context kind-"$cluster" delete secret stage-workload -n argocd --ignore-not-found=true 2>/dev/null || true
    elif [ "$cluster" = "prod-control" ]; then
        echo_info "  Unregistering workload clusters..."
        kubectl --context kind-"$cluster" delete secret prod-workload -n argocd --ignore-not-found=true 2>/dev/null || true
    fi
    
    # Delete ArgoCD namespace (this removes all ArgoCD components)
    # Use --force --grace-period=0 to bypass finalizers if needed
    echo_info "  Deleting ArgoCD namespace..."
    kubectl --context kind-"$cluster" delete namespace argocd --ignore-not-found=true --timeout=60s 2>/dev/null || {
        echo_warn "  Namespace deletion timed out, forcing deletion..."
        kubectl --context kind-"$cluster" delete namespace argocd --force --grace-period=0 --ignore-not-found=true 2>/dev/null || true
    }
    
    echo_info "  ✓ $cluster cleaned"
}

# Clean all clusters
clean_cluster stage-control
clean_cluster stage-workload
clean_cluster prod-control
clean_cluster prod-workload

echo ""
echo_info "✓ All deployments cleaned! Clusters remain intact."
echo ""
echo "Clusters are now in a clean state. Run 'make deploy' to redeploy."

