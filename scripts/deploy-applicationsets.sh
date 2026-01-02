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
for cluster in stage-control stage-workload prod-control prod-workload; do
    if ! kubectl --context kind-"$cluster" cluster-info &>/dev/null; then
        echo_error "Cluster $cluster does not exist. Please run 'make setup-kind' first."
        exit 1
    fi
done

# Install ArgoCD on control clusters
install_argocd() {
    local cluster=$1
    local namespace="argocd"
    
    echo_info "Installing ArgoCD on $cluster..."
    
    if kubectl --context kind-"$cluster" get namespace $namespace &>/dev/null && \
       kubectl --context kind-"$cluster" get deployment argocd-server -n $namespace &>/dev/null; then
        echo_warn "ArgoCD already installed on $cluster, skipping..."
        return
    fi
    
    kubectl --context kind-"$cluster" create namespace $namespace --dry-run=client -o yaml | kubectl --context kind-"$cluster" apply -f -
    kubectl --context kind-"$cluster" apply -n $namespace -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    
    echo_info "Waiting for ArgoCD to be ready..."
    kubectl --context kind-"$cluster" wait --for=condition=available deployment/argocd-server -n $namespace --timeout=300s
    kubectl --context kind-"$cluster" wait --for=condition=available deployment/argocd-repo-server -n $namespace --timeout=300s
    kubectl --context kind-"$cluster" wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-application-controller -n $namespace --timeout=300s
    
    local admin_password
    admin_password=$(kubectl --context kind-"$cluster" -n $namespace get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -n "$admin_password" ]; then
        ARGOCD_PASSWORDS["$cluster"]="$admin_password"
    fi
}

create_appproject() {
    echo_info "Creating AppProject 'msvc-system' on $1..."
    kubectl --context kind-"$1" apply -f "$PROJECT_ROOT/bootstrap/appproject-msvc-system.yaml"
}

# Get cluster IP address
get_cluster_ip() {
    case "$1" in
        stage-control)  echo "172.20.0.5" ;;
        stage-workload)  echo "172.20.0.6" ;;
        prod-control)    echo "172.20.0.15" ;;
        prod-workload)   echo "172.20.0.16" ;;
        *)               echo "" ;;
    esac
}

# Register workload clusters
register_workload_cluster() {
    local control_cluster=$1
    local workload_cluster=$2
    local workload_ip
    workload_ip=$(get_cluster_ip "$workload_cluster")
    
    [ -z "$workload_ip" ] && { echo_error "Unknown cluster: $workload_cluster"; exit 1; }
    
    echo_info "Registering $workload_cluster in ArgoCD on $control_cluster..."
    
    kubectl --context kind-"$control_cluster" delete secret "$workload_cluster" -n argocd --ignore-not-found=true &>/dev/null
    
    echo_info "Setting up ArgoCD manager resources on $workload_cluster..."
    kubectl --context kind-"$workload_cluster" apply -f "$PROJECT_ROOT/bootstrap/argocd-manager-serviceaccount.yaml"
    kubectl --context kind-"$workload_cluster" apply -f "$PROJECT_ROOT/bootstrap/argocd-manager-clusterrole.yaml"
    kubectl --context kind-"$workload_cluster" apply -f "$PROJECT_ROOT/bootstrap/argocd-manager-clusterrolebinding.yaml"
    
    echo_info "Getting ServiceAccount token..."
    local bearer_token
    local token_secret
    token_secret=$(kubectl --context kind-"$workload_cluster" get secret -n kube-system -o jsonpath='{.items[?(@.metadata.annotations.kubernetes\.io/service-account\.name=="argocd-manager")].name}' 2>/dev/null | head -1)
    
    if [ -n "$token_secret" ]; then
        bearer_token=$(kubectl --context kind-"$workload_cluster" get secret "$token_secret" -n kube-system -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
    else
        kubectl --context kind-"$workload_cluster" apply -f - <<EOF &>/dev/null
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
            bearer_token=$(kubectl --context kind-"$workload_cluster" get secret argocd-manager-token -n kube-system -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
            [ -n "$bearer_token" ] && break
            attempt=$((attempt + 1))
            sleep 1
        done
    fi
    
    [ -z "$bearer_token" ] && { echo_error "Failed to get bearer token"; return 1; }
    
    local config_json
    config_json=$(jq -n --arg token "$bearer_token" '{"bearerToken": $token, "tlsClientConfig": {"insecure": true}}')
    
    kubectl --context kind-"$control_cluster" create secret generic "$workload_cluster" \
        --from-literal=name="$workload_cluster" \
        --from-literal=server="https://${workload_ip}:6443" \
        --from-literal=config="$config_json" \
        -n argocd \
        --dry-run=client -o yaml | kubectl --context kind-"$control_cluster" apply -f - &>/dev/null
    
    kubectl --context kind-"$control_cluster" label secret "$workload_cluster" -n argocd argocd.argoproj.io/secret-type=cluster --overwrite &>/dev/null
    
    echo_info "Verifying cluster registration..."
    local secret_config
    secret_config=$(kubectl --context kind-"$control_cluster" get secret "$workload_cluster" -n argocd -o jsonpath='{.data.config}' 2>/dev/null | base64 -d)
    
    [ -z "$secret_config" ] && { echo_error "Secret config missing"; return 1; }
    echo "$secret_config" | jq -e '.tlsClientConfig.insecure == true' &>/dev/null || { echo_error "Secret missing insecure: true"; return 1; }
    kubectl --context kind-"$control_cluster" get secret "$workload_cluster" -n argocd -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}' 2>/dev/null | grep -q "cluster" || { echo_error "Secret missing label"; return 1; }
    
    echo_info "✓ Cluster $workload_cluster registered successfully"
}

# Deploy applicationsets helm chart
deploy_applicationsets() {
    local cluster=$1
    local values_file="$PROJECT_ROOT/values/argo-cd-applicationsets/values.control-$2.yaml"
    
    echo_info "Deploying applicationsets on $cluster..."
    
    local helm_args=("upgrade" "--install" "argo-cd-applicationsets" "$PROJECT_ROOT/helm/argo-cd-applicationsets" \
        "--namespace" "argocd" "--create-namespace" "--kube-context" "kind-$cluster" "--wait" "--timeout" "5m")
    
    [ -f "$values_file" ] && helm_args+=("-f" "$values_file")
    
    helm "${helm_args[@]}"
}

echo_info "Starting applicationsets deployment..."

for cluster in stage-control stage-workload prod-control prod-workload; do
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
declare -A PORTS=([stage-control]=8080 [stage-workload]=8082 [prod-control]=8081 [prod-workload]=8083)
for cluster in "${!PORTS[@]}"; do
    [ -n "${ARGOCD_PASSWORDS[$cluster]:-}" ] && echo "  $cluster: https://localhost:${PORTS[$cluster]} (admin/${ARGOCD_PASSWORDS[$cluster]})"
done

