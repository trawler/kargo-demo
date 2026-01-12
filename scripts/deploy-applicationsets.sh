#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration: Set CLUSTER_SET to "kind" or "poc" (default: kind)
CLUSTER_SET="${CLUSTER_SET:-kind}"

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

# Get kubectl context name for a cluster
get_context() {
    local cluster=$1
    if [ "$CLUSTER_SET" = "poc" ]; then
        echo "poc-$cluster"
    else
        echo "kind-$cluster"
    fi
}

# Check if cluster is a kind cluster
is_kind_cluster() {
    [ "$CLUSTER_SET" = "kind" ]
}

# Define clusters based on CLUSTER_SET
if [ "$CLUSTER_SET" = "poc" ]; then
    CLUSTERS=(poc-stage-control poc-stage-workload poc-prod-control poc-prod-workload)
    CLUSTER_NAMES=(stage-control stage-workload prod-control prod-workload)
else
    CLUSTERS=(stage-control stage-workload prod-control prod-workload)
    CLUSTER_NAMES=("${CLUSTERS[@]}")
fi

# Check if clusters exist
echo_info "Checking clusters (CLUSTER_SET=$CLUSTER_SET)..."
for i in "${!CLUSTERS[@]}"; do
    cluster="${CLUSTERS[$i]}"
    context=$(get_context "${CLUSTER_NAMES[$i]}")
    if ! kubectl --context "$context" cluster-info &>/dev/null; then
        echo_error "Cluster $cluster (context: $context) does not exist."
        if is_kind_cluster; then
            echo_error "Please run 'make setup-kind' first."
        else
            echo_error "Please ensure kubectl context '$context' is configured."
        fi
        exit 1
    fi
done
echo_info "✓ All clusters are accessible"

# Install MetalLB LoadBalancer provider (only for kind clusters)
install_metallb() {
    local cluster=$1
    local context=$(get_context "$cluster")
    
    if ! is_kind_cluster; then
        echo_info "Skipping MetalLB for $cluster (not a kind cluster, LoadBalancer should be available)"
        return
    fi
    
    echo_info "Installing MetalLB on $cluster..."
    
    # Check if MetalLB is already installed
    if kubectl --context "$context" get namespace metallb-system &>/dev/null; then
        echo_warn "MetalLB already installed on $cluster, skipping..."
        return
    fi
    
    # Install MetalLB
    kubectl --context "$context" apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml
    
    echo_info "Waiting for MetalLB to be ready..."
    kubectl --context "$context" wait --namespace metallb-system \
        --for=condition=ready pod \
        --selector=app=metallb \
        --timeout=90s
    
    # Get the Docker network subnet for kind
    # MetalLB needs an IP range within the kind-api network (172.20.0.0/16)
    # Cluster IPs are: 172.20.0.5, 172.20.0.6, 172.20.0.15, 172.20.0.16
    # Using 172.20.240.0/24 range which doesn't conflict with cluster IPs
    local ip_range="172.20.240.0/24"
    
    # Create MetalLB IPAddressPool
    kubectl --context "$context" apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - ${ip_range}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
EOF
    
    echo_info "✓ MetalLB installed and configured on $cluster"
}

# Install ArgoCD on control clusters
install_argocd() {
    local cluster=$1
    local context=$(get_context "$cluster")
    local namespace="argocd"
    
    echo_info "Installing ArgoCD on $cluster (context: $context)..."
    
    if kubectl --context "$context" get namespace $namespace &>/dev/null && \
       kubectl --context "$context" get deployment argocd-server -n $namespace &>/dev/null; then
        echo_warn "ArgoCD already installed on $cluster, skipping..."
        return
    fi
    
    kubectl --context "$context" create namespace $namespace --dry-run=client -o yaml | kubectl --context "$context" apply -f -
    kubectl --context "$context" apply -n $namespace -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    
    echo_info "Waiting for ArgoCD to be ready..."
    kubectl --context "$context" wait --for=condition=available deployment/argocd-server -n $namespace --timeout=300s
    kubectl --context "$context" wait --for=condition=available deployment/argocd-repo-server -n $namespace --timeout=300s
    kubectl --context "$context" wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-application-controller -n $namespace --timeout=300s
    
    local admin_password
    admin_password=$(kubectl --context "$context" -n $namespace get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -n "$admin_password" ]; then
        ARGOCD_PASSWORDS["$cluster"]="$admin_password"
    fi
    
    # For POC clusters, configure ArgoCD server service as LoadBalancer
    if ! is_kind_cluster; then
        echo_info "Configuring ArgoCD server service as LoadBalancer for $cluster..."
        # Wait a moment for the service to be created
        sleep 2
        # Check if service exists and patch it
        if kubectl --context "$context" get service argocd-server -n $namespace &>/dev/null; then
            kubectl --context "$context" patch service argocd-server -n $namespace -p '{"spec":{"type":"LoadBalancer"}}' 2>/dev/null || {
                echo_warn "Failed to patch argocd-server service"
            }
            echo_info "✓ ArgoCD server service configured as LoadBalancer"
        else
            echo_warn "argocd-server service not found, skipping LoadBalancer configuration"
        fi
    fi
}

create_appproject() {
    local cluster=$1
    local context=$(get_context "$cluster")
    echo_info "Creating AppProject 'msvc-system' on $cluster (context: $context)..."
    kubectl --context "$context" apply -f "$PROJECT_ROOT/bootstrap/appproject-msvc-system.yaml"
}

# Get cluster IP address or API server URL
get_cluster_server() {
    local cluster=$1
    local context=$(get_context "$cluster")
    
    if is_kind_cluster; then
        # For kind clusters, use static IPs
        case "$cluster" in
            stage-control)  echo "https://172.20.0.5:6443" ;;
            stage-workload)  echo "https://172.20.0.6:6443" ;;
            prod-control)    echo "https://172.20.0.15:6443" ;;
            prod-workload)   echo "https://172.20.0.16:6443" ;;
            *)               echo "" ;;
        esac
    else
        # For metakube/POC clusters, get API server from cluster config
        # Get the cluster name from the context, then get the server URL
        local cluster_name
        cluster_name=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$context\")].context.cluster}" 2>/dev/null || echo "")
        
        if [ -z "$cluster_name" ]; then
            echo ""
            return
        fi
        
        # Get the server URL from the cluster name
        local server
        server=$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$cluster_name\")].cluster.server}" 2>/dev/null || echo "")
        
        if [ -z "$server" ]; then
            # Fallback: try to get server directly from context if cluster name lookup fails
            server=$(kubectl config view --raw -o jsonpath="{.contexts[?(@.name==\"$context\")].context.cluster}" 2>/dev/null | xargs -I {} kubectl config view -o jsonpath="{.clusters[?(@.name==\"{}\")].cluster.server}" 2>/dev/null || echo "")
        fi
        
        echo "$server"
    fi
}

# Register workload clusters
register_workload_cluster() {
    local control_cluster=$1
    local workload_cluster=$2
    local control_context=$(get_context "$control_cluster")
    local workload_context=$(get_context "$workload_cluster")
    local workload_server
    workload_server=$(get_cluster_server "$workload_cluster")
    
    [ -z "$workload_server" ] && { echo_error "Unknown cluster or cannot get server URL: $workload_cluster"; exit 1; }
    
    echo_info "Registering $workload_cluster in ArgoCD on $control_cluster..."
    
    kubectl --context "$control_context" delete secret "$workload_cluster" -n argocd --ignore-not-found=true &>/dev/null
    
    echo_info "Setting up ArgoCD manager resources on $workload_cluster..."
    kubectl --context "$workload_context" apply -f "$PROJECT_ROOT/bootstrap/argocd-manager-serviceaccount.yaml"
    kubectl --context "$workload_context" apply -f "$PROJECT_ROOT/bootstrap/argocd-manager-clusterrole.yaml"
    kubectl --context "$workload_context" apply -f "$PROJECT_ROOT/bootstrap/argocd-manager-clusterrolebinding.yaml"
    
    echo_info "Getting ServiceAccount token..."
    local bearer_token
    local token_secret
    token_secret=$(kubectl --context "$workload_context" get secret -n kube-system -o jsonpath='{.items[?(@.metadata.annotations.kubernetes\.io/service-account\.name=="argocd-manager")].name}' 2>/dev/null | head -1)
    
    if [ -n "$token_secret" ]; then
        bearer_token=$(kubectl --context "$workload_context" get secret "$token_secret" -n kube-system -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
    else
        kubectl --context "$workload_context" apply -f - <<EOF &>/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF
        local attempt=0
        while [ $attempt -lt 10 ]; do
            bearer_token=$(kubectl --context "$workload_context" get secret argocd-manager-token -n kube-system -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
            [ -n "$bearer_token" ] && break
            attempt=$((attempt + 1))
            sleep 1
        done
    fi
    
    [ -z "$bearer_token" ] && { echo_error "Failed to get bearer token"; return 1; }
    
    # For metakube clusters, we might need to use secure TLS instead of insecure
    local tls_config
    if is_kind_cluster; then
        tls_config='{"insecure": true}'
    else
        # For metakube, try to get CA data from cluster config
        local ca_data
        ca_data=$(kubectl --context "$workload_context" config view --raw -o jsonpath="{.clusters[?(@.name==\"$workload_context\")].cluster.certificate-authority-data}" 2>/dev/null || echo "")
        if [ -n "$ca_data" ]; then
            tls_config=$(jq -n --arg ca "$ca_data" '{"caData": $ca}')
        else
            tls_config='{"insecure": true}'
            echo_warn "Could not get CA data for $workload_cluster, using insecure TLS"
        fi
    fi
    
    local config_json
    config_json=$(jq -n --arg token "$bearer_token" --argjson tls "$tls_config" '{"bearerToken": $token, "tlsClientConfig": $tls}')
    
    kubectl --context "$control_context" create secret generic "$workload_cluster" \
        --from-literal=name="$workload_cluster" \
        --from-literal=server="$workload_server" \
        --from-literal=config="$config_json" \
        -n argocd \
        --dry-run=client -o yaml | kubectl --context "$control_context" apply -f - &>/dev/null
    
    kubectl --context "$control_context" label secret "$workload_cluster" -n argocd argocd.argoproj.io/secret-type=cluster --overwrite &>/dev/null
    
    echo_info "Verifying cluster registration..."
    local secret_config
    secret_config=$(kubectl --context "$control_context" get secret "$workload_cluster" -n argocd -o jsonpath='{.data.config}' 2>/dev/null | base64 -d)
    
    [ -z "$secret_config" ] && { echo_error "Secret config missing"; return 1; }
    kubectl --context "$control_context" get secret "$workload_cluster" -n argocd -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}' 2>/dev/null | grep -q "cluster" || { echo_error "Secret missing label"; return 1; }
    
    echo_info "✓ Cluster $workload_cluster registered successfully"
}

# Deploy applicationsets helm chart
deploy_applicationsets() {
    local cluster=$1
    local context=$(get_context "$cluster")
    local env=$2
    local values_file
    
    # Use POC-specific values files if CLUSTER_SET is poc
    if [ "$CLUSTER_SET" = "poc" ]; then
        values_file="$PROJECT_ROOT/values/argo-cd-applicationsets/values.control-$env-poc.yaml"
    else
        values_file="$PROJECT_ROOT/values/argo-cd-applicationsets/values.control-$env.yaml"
    fi
    
    echo_info "Deploying applicationsets on $cluster (context: $context)..."
    
    local helm_args=("upgrade" "--install" "argo-cd-applicationsets" "$PROJECT_ROOT/helm/argo-cd-applicationsets" \
        "--namespace" "argocd" "--create-namespace" "--kube-context" "$context" "--wait" "--timeout" "5m")
    
    [ -f "$values_file" ] && helm_args+=("-f" "$values_file")
    
    helm "${helm_args[@]}"
}

echo_info "Starting applicationsets deployment (CLUSTER_SET=$CLUSTER_SET)..."

# Install MetalLB on all clusters first (only for kind clusters)
if is_kind_cluster; then
    echo_info "Installing MetalLB LoadBalancer provider..."
    for cluster in "${CLUSTER_NAMES[@]}"; do
        install_metallb "$cluster"
    done
else
    echo_info "Skipping MetalLB (not needed for metakube clusters)"
fi

# Install ArgoCD and create AppProjects
for cluster in "${CLUSTER_NAMES[@]}"; do
    install_argocd "$cluster"
    create_appproject "$cluster"
done

echo_info "Registering workload clusters..."
register_workload_cluster stage-control stage-workload || {
    echo_error "Failed to register stage-workload. Stopping deployment."
    exit 1
}

register_workload_cluster prod-control prod-workload || echo_warn "Prod cluster registration failed, continuing..."

deploy_applicationsets stage-control stage
deploy_applicationsets prod-control prod

echo_info "✓ Applicationsets deployment complete!"
echo ""
echo "ArgoCD Access Information:"
if is_kind_cluster; then
    declare -A PORTS=([stage-control]=8080 [stage-workload]=8082 [prod-control]=8081 [prod-workload]=8083)
    for cluster in "${!PORTS[@]}"; do
        [ -n "${ARGOCD_PASSWORDS[$cluster]:-}" ] && echo "  $cluster: https://localhost:${PORTS[$cluster]} (admin/${ARGOCD_PASSWORDS[$cluster]})"
    done
else
    echo "  For POC clusters, access ArgoCD via LoadBalancer services or ingress"
    for cluster in "${CLUSTER_NAMES[@]}"; do
        [ -n "${ARGOCD_PASSWORDS[$cluster]:-}" ] && echo "  $cluster: admin/${ARGOCD_PASSWORDS[$cluster]}"
    done
fi

