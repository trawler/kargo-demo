#!/bin/bash

# Port forward all services for kargo-demo
# ArgoCD: localhost:8080 (stage), localhost:8081 (prod)
# Kargo: localhost:9080 (stage), localhost:9081 (prod)

set -e

echo "🚀 Starting port-forwards..."
echo ""
echo "ArgoCD:"
echo "  Stage: https://localhost:8080"
echo "  Prod:  https://localhost:8081"
echo ""
echo "Kargo:"
echo "  Stage: https://localhost:9080"
echo "  Prod:  https://localhost:9081"
echo ""
echo "Press Ctrl+C to stop all port-forwards"
echo ""

# Function to cleanup on exit
cleanup() {
    echo ""
    echo "🛑 Stopping port-forwards..."
    # Kill all background processes in this script
    jobs -p | xargs -r kill 2>/dev/null || true
    echo "✓ All port-forwards stopped"
}

trap cleanup EXIT

# Start port-forwards in background
kubectl --context kind-stage-control port-forward -n argocd svc/argocd-server 8080:443 --address=127.0.0.1 > /tmp/pf-argocd-stage.log 2>&1 &
echo "✓ ArgoCD Stage (8080)"

kubectl --context kind-prod-control port-forward -n argocd svc/argocd-server 8081:443 --address=127.0.0.1 > /tmp/pf-argocd-prod.log 2>&1 &
echo "✓ ArgoCD Prod (8081)"

sleep 2

kubectl --context kind-stage-control port-forward -n kargo svc/kargo-api 9080:443 --address=127.0.0.1 > /tmp/pf-kargo-stage.log 2>&1 &
echo "✓ Kargo Stage (9080)"

kubectl --context kind-prod-control port-forward -n kargo svc/kargo-api 9081:443 --address=127.0.0.1 > /tmp/pf-kargo-prod.log 2>&1 &
echo "✓ Kargo Prod (9081)"

echo ""
echo "All port-forwards active. Press Ctrl+C to stop."
echo ""

# Keep the script running
wait
