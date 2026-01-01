#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Store passwords for summary at the end
declare -A ARGOCD_PASSWORDS

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() {
    echo -e "${GREEN}ℹ${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

echo_error() {
    echo -e "${RED}✗${NC} $1"
}

# Check if clusters exist
check_cluster() {
    local cluster=$1
    if ! kubectl --context kind-"$cluster" cluster-info &>/dev/null; then
        echo_error "Cluster $cluster does not exist. Please run 'make setup-kind' first."
        exit 1
    fi
}

echo_info "Checking clusters..."
check_cluster stage-control
check_cluster stage-workload
check_cluster prod-control
check_cluster prod-workload

# Install ArgoCD on control clusters
install_argocd() {
    local cluster=$1
    local namespace="argocd"
    
    echo_info "Installing ArgoCD on $cluster..."
    
    # Check if ArgoCD is already installed
    if kubectl --context kind-"$cluster" get namespace $namespace &>/dev/null && \
       kubectl --context kind-"$cluster" get deployment argocd-server -n $namespace &>/dev/null; then
        echo_warn "ArgoCD already installed on $cluster, skipping..."
        return
    fi
    
    # Create namespace
    kubectl --context kind-"$cluster" create namespace $namespace --dry-run=client -o yaml | kubectl --context kind-"$cluster" apply -f -
    
    # Install ArgoCD
    kubectl --context kind-"$cluster" apply -n $namespace -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    
    # Wait for ArgoCD to be ready
    echo_info "Waiting for ArgoCD to be ready on $cluster..."
    kubectl --context kind-"$cluster" wait --for=condition=available deployment/argocd-server -n $namespace --timeout=300s
    kubectl --context kind-"$cluster" wait --for=condition=available deployment/argocd-repo-server -n $namespace --timeout=300s
    # argocd-application-controller is a StatefulSet, wait for the pod to be ready
    kubectl --context kind-"$cluster" wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-application-controller -n $namespace --timeout=300s
    
    # Get and display the admin password
    echo_info "Getting ArgoCD admin password..."
    local admin_password
    admin_password=$(kubectl --context kind-"$cluster" -n $namespace get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "")
    
    if [ -n "$admin_password" ]; then
        ARGOCD_PASSWORDS["$cluster"]="$admin_password"
        echo_info "ArgoCD installed on $cluster"
    else
        echo_warn "Could not retrieve ArgoCD admin password. You may need to check the secret manually."
        echo_info "  Run: kubectl --context kind-$cluster -n $namespace get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    fi
}

# Create AppProject - required before ApplicationSets can be deployed
# Based on verification: all ApplicationSets in helm/ use 'msvc-system'
# The 'default' project is automatically created by ArgoCD
create_appproject() {
    local cluster=$1
    local namespace="argocd"
    
    echo_info "Creating AppProject 'msvc-system' on $cluster..."
    kubectl --context kind-"$cluster" apply -f "$PROJECT_ROOT/bootstrap/appproject-msvc-system.yaml"
}

# Register workload clusters
register_workload_cluster() {
    local control_cluster=$1
    local workload_cluster=$2
    local workload_port=${3:-6443}
    
    echo_info "Registering $workload_cluster in ArgoCD on $control_cluster..."
    
    # Check if cluster secret already exists
    if kubectl --context kind-"$control_cluster" get secret "$workload_cluster" -n argocd &>/dev/null; then
        echo_warn "Cluster $workload_cluster already registered, skipping..."
        return
    fi
    
    # Get kubeconfig
    local kubeconfig="/tmp/kargo-demo-kubeconfigs/${workload_cluster}-kubeconfig.yaml"
    if [ ! -f "$kubeconfig" ]; then
        echo_info "Extracting kubeconfig for $workload_cluster..."
        mkdir -p /tmp/kargo-demo-kubeconfigs
        kind get kubeconfig --name "$workload_cluster" > "$kubeconfig"
    fi
    
    # Get ArgoCD admin password
    echo_info "Getting ArgoCD admin password..."
    local argocd_password
    argocd_password=$(kubectl --context kind-"$control_cluster" -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "")
    
    if [ -z "$argocd_password" ]; then
        echo_error "Could not get ArgoCD admin password. ArgoCD may not be ready yet."
        echo_error "  Run: kubectl --context kind-$control_cluster -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
        exit 1
    fi
    
    # Port forward ArgoCD server
    echo_info "Setting up port-forward for ArgoCD server..."
    local port
    if [ "$control_cluster" = "stage-control" ]; then
        port=8080
    else
        port=8081
    fi
    
    # Kill existing port-forward if any
    pkill -f "port-forward.*argocd-server.*$port" || true
    sleep 1
    
    # Start port-forward in background
    kubectl --context kind-"$control_cluster" port-forward -n argocd svc/argocd-server $port:443 --address=127.0.0.1 > /tmp/argocd-pf-"$control_cluster".log 2>&1 &
    local pf_pid=$!
    
    # Wait for port-forward to be ready
    sleep 3
    
    # Login to ArgoCD
    echo_info "Logging in to ArgoCD..."
    if ! argocd login localhost:$port --username admin --password "$argocd_password" --insecure --grpc-web 2>/dev/null; then
        echo_error "Failed to login to ArgoCD"
        kill $pf_pid 2>/dev/null || true
        exit 1
    fi
    
    # Add cluster
    echo_info "Adding $workload_cluster cluster..."
    if argocd cluster add kind-"$workload_cluster" \
        --name "$workload_cluster" \
        --kubeconfig "$kubeconfig" \
        --server https://"$workload_cluster":"$workload_port" \
        --insecure \
        --grpc-web \
        --yes 2>/dev/null; then
        echo_info "Cluster $workload_cluster registered successfully"
    else
        echo_warn "Failed to add cluster via argocd CLI, trying manual secret creation..."
        
        # Manual secret creation as fallback
        kubectl --context kind-"$control_cluster" create secret generic "$workload_cluster" \
            --from-literal=name="$workload_cluster" \
            --from-literal=server=https://"$workload_cluster":"$workload_port" \
            --from-file=config="$kubeconfig" \
            -n argocd \
            --dry-run=client -o yaml | kubectl --context kind-"$control_cluster" apply -f -
        
        kubectl --context kind-"$control_cluster" label secret "$workload_cluster" \
            -n argocd \
            argocd.argoproj.io/secret-type=cluster \
            --overwrite
        
        echo_info "Cluster $workload_cluster registered via manual secret"
    fi
    
    # Clean up port-forward
    kill $pf_pid 2>/dev/null || true
}

# Deploy applicationsets helm chart
deploy_applicationsets() {
    local cluster=$1
    local environment=$2
    
    echo_info "Deploying applicationsets on $cluster (environment: $environment)..."
    
    # Determine values file
    local values_file
    if [ "$environment" = "stage" ]; then
        values_file="$PROJECT_ROOT/values/argo-cd-applicationsets/values.control-stage.yaml"
    else
        values_file="$PROJECT_ROOT/values/argo-cd-applicationsets/values.control-prod.yaml"
    fi
    
    # Build helm command arguments
    local helm_args=(
        "upgrade" "--install" "argo-cd-applicationsets"
        "$PROJECT_ROOT/helm/argo-cd-applicationsets"
        "--namespace" "argocd"
        "--create-namespace"
        "--kube-context" "kind-$cluster"
    )
    
    # Add values file if it exists
    if [ -f "$values_file" ]; then
        helm_args+=("-f" "$values_file")
    else
        echo_warn "Values file $values_file not found, using defaults"
    fi
    
    # Add wait and timeout
    helm_args+=("--wait" "--timeout" "5m")
    
    # Execute helm command
    helm "${helm_args[@]}"
    
    echo_info "Applicationsets deployed on $cluster"
}

# Main deployment flow
echo_info "Starting applicationsets deployment..."

# Install ArgoCD on control clusters
install_argocd stage-control
install_argocd prod-control

# Create AppProject (required before ApplicationSets can reference it)
create_appproject stage-control
create_appproject prod-control

# Register workload clusters
register_workload_cluster stage-control stage-workload
register_workload_cluster prod-control prod-workload

# Deploy applicationsets
deploy_applicationsets stage-control stage
deploy_applicationsets prod-control prod

echo_info "✓ Applicationsets deployment complete!"
echo ""
echo "=========================================="
echo "ArgoCD Access Information"
echo "=========================================="
echo ""
for cluster in stage-control prod-control; do
    if [ -n "${ARGOCD_PASSWORDS[$cluster]:-}" ]; then
        port=""
        if [ "$cluster" = "stage-control" ]; then
            port=8080
        else
            port=8081
        fi
        echo "Cluster: $cluster"
        echo "  URL: https://localhost:$port"
        echo "  Username: admin"
        echo "  Password: ${ARGOCD_PASSWORDS[$cluster]}"
        echo ""
    fi
done
echo "=========================================="
echo ""
echo "To start port-forwards, run:"
echo "  ./port-forward-all.sh"
echo ""
echo "Or use:"
echo "  make port-forward"
echo ""
echo "Verification commands:"
echo "  # Check AppProjects:"
echo "  kubectl --context kind-stage-control get appproject -n argocd"
echo "  kubectl --context kind-prod-control get appproject -n argocd"
echo ""
echo "  # Check ApplicationSets:"
echo "  kubectl --context kind-stage-control get applicationsets -n argocd"
echo "  kubectl --context kind-prod-control get applicationsets -n argocd"

