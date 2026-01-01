#!/bin/bash
set -e

echo "Destroying kind clusters..."

# Delete clusters
kind delete cluster --name stage-control 2>/dev/null || echo "stage-control cluster not found"
kind delete cluster --name stage-workload 2>/dev/null || echo "stage-workload cluster not found"
kind delete cluster --name prod-control 2>/dev/null || echo "prod-control cluster not found"
kind delete cluster --name prod-workload 2>/dev/null || echo "prod-workload cluster not found"

# Clean up kubeconfigs
rm -rf /tmp/kargo-demo-kubeconfigs

echo "✓ All kind clusters destroyed!"

