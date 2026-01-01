#!/usr/bin/env bash
set -euo pipefail

echo "Setting up kind clusters with static IP addresses..."

# IP mapping
declare -A CLUSTER_IPS=(
    [stage-control]="172.20.0.5"
    [stage-workload]="172.20.0.6"
    [prod-control]="172.20.0.15"
    [prod-workload]="172.20.0.16"
)

# Host port mapping (for kubectl access from host)
declare -A HOST_PORTS=(
    [stage-control]="6443"
    [stage-workload]="6444"
    [prod-control]="6445"
    [prod-workload]="6446"
)

# Ensure kind-api network exists
echo "Ensuring kind-api network exists..."
if ! docker network inspect kind-api &>/dev/null; then
    docker network create --driver=bridge --subnet=172.20.0.0/16 kind-api
    echo "  ✓ Created kind-api network"
else
    echo "  ✓ kind-api network exists"
fi

# Function to create cluster
create_cluster() {
    local cluster_name=$1
    local ip="${CLUSTER_IPS[$cluster_name]}"
    local host_port="${HOST_PORTS[$cluster_name]}"
    local container="${cluster_name}-control-plane"
    
    echo ""
    echo "=== Creating ${cluster_name} ==="
    
    # Create Kind cluster (stays on 'kind' network)
    cat <<EOF | kind create cluster --name "$cluster_name" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 6443
    hostPort: ${host_port}
    protocol: TCP
EOF
    
    echo "  ✓ Cluster created on 'kind' network"
    
    # Add to kind-api network with specific IP
    echo "  Adding to kind-api network with IP ${ip}..."
    
    # Free IP if occupied
    local occupant=$(docker network inspect kind-api -f '{{range .Containers}}{{if eq .IPv4Address "'"$ip"'/16"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || true)
    if [ -n "$occupant" ] && [ "$occupant" != "$container" ]; then
        echo "  Freeing IP from ${occupant}..."
        docker network disconnect kind-api "$occupant" 2>/dev/null || true
    fi
    
    # Connect to kind-api (don't disconnect from kind!)
    if docker network connect --ip "$ip" kind-api "$container" 2>&1; then
        echo "  ✓ Connected to kind-api at ${ip}"
    else
        echo "  ✗ Failed to assign IP ${ip}"
        return 1
    fi
    
    # Verify
    echo "  Verifying cluster..."
    kubectl --context "kind-${cluster_name}" cluster-info &>/dev/null
    echo "  ✓ Cluster accessible via kubeconfig (127.0.0.1:${host_port})"
    
    # Show both IPs
    echo "  Networks:"
    docker inspect "$container" --format '    kind: {{(index .NetworkSettings.Networks "kind").IPAddress}}'
    docker inspect "$container" --format '    kind-api: {{(index .NetworkSettings.Networks "kind-api").IPAddress}}'
}

# Create all clusters
for cluster in stage-control stage-workload prod-control prod-workload; do
    create_cluster "$cluster"
done

# Wait for clusters to be ready
echo ""
echo "Waiting for all clusters to be ready..."
for cluster in stage-control stage-workload prod-control prod-workload; do
    echo "  ${cluster}..."
    kubectl --context "kind-${cluster}" wait --for=condition=Ready nodes --all --timeout=60s
    echo "  ✓ ${cluster} ready"
done

# Export kubeconfigs
echo ""
echo "Exporting kubeconfigs..."
mkdir -p /tmp/kargo-demo-kubeconfigs
kind get kubeconfig --name stage-workload > /tmp/kargo-demo-kubeconfigs/stage-workload-kubeconfig.yaml
kind get kubeconfig --name prod-workload > /tmp/kargo-demo-kubeconfigs/prod-workload-kubeconfig.yaml
echo "  ✓ Kubeconfigs saved"

# Summary
echo ""
echo "✓ Setup complete!"
echo ""
echo "Clusters and their IPs:"
for cluster in stage-control stage-workload prod-control prod-workload; do
    ip="${CLUSTER_IPS[$cluster]}"
    port="${HOST_PORTS[$cluster]}"
    echo "  ${cluster}:"
    echo "    - kind-api IP: ${ip} (for ArgoCD/ApplicationSet)"
    echo "    - Host access: 127.0.0.1:${port} (for kubectl)"
done
echo ""
echo "For ArgoCD, use the kind-api IPs (172.20.0.x) in your ApplicationSet"
echo "For kubectl from host, use the contexts: kind-{cluster-name}"