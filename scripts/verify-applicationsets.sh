#!/bin/bash
# Script to verify ApplicationSet templates render correctly

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🔍 Verifying ApplicationSet templates..."
echo ""

# Test Kind values
echo "=== Testing Kind values (values.control-prod.yaml) ==="
helm template argo-cd-applicationsets "$PROJECT_ROOT/helm/argo-cd-applicationsets" \
    -f "$PROJECT_ROOT/values/argo-cd-applicationsets/values.control-prod.yaml" \
    --namespace argocd 2>&1 | grep -A 10 "cluster: prod-workload" || echo "No prod-workload cluster found"
echo ""

# Test POC values
echo "=== Testing POC values (values.control-prod-poc.yaml) ==="
helm template argo-cd-applicationsets "$PROJECT_ROOT/helm/argo-cd-applicationsets" \
    -f "$PROJECT_ROOT/values/argo-cd-applicationsets/values.control-prod-poc.yaml" \
    --namespace argocd 2>&1 | grep -A 10 "cluster: prod-workload" || echo "No prod-workload cluster found"
echo ""

# Test stage values
echo "=== Testing Stage values (values.control-stage.yaml) ==="
helm template argo-cd-applicationsets "$PROJECT_ROOT/helm/argo-cd-applicationsets" \
    -f "$PROJECT_ROOT/values/argo-cd-applicationsets/values.control-stage.yaml" \
    --namespace argocd 2>&1 | grep -A 10 "cluster: stage-workload" || echo "No stage-workload cluster found"
echo ""

# Test stage POC values
echo "=== Testing Stage POC values (values.control-stage-poc.yaml) ==="
helm template argo-cd-applicationsets "$PROJECT_ROOT/helm/argo-cd-applicationsets" \
    -f "$PROJECT_ROOT/values/argo-cd-applicationsets/values.control-stage-poc.yaml" \
    --namespace argocd 2>&1 | grep -A 10 "cluster: stage-workload" || echo "No stage-workload cluster found"
echo ""

echo "✅ Verification complete!"
echo ""
echo "To see full rendered manifests, run:"
echo "  helm template argo-cd-applicationsets helm/argo-cd-applicationsets -f values/argo-cd-applicationsets/values.control-prod.yaml --namespace argocd"
