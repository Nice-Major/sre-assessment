#!/bin/bash
# =============================================================================
# Deploy Google Online Boutique + PostgreSQL (required for Section 3.2)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Deploying Google Online Boutique ==="
kubectl apply -n online-boutique \
  -f https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/main/release/kubernetes-manifests.yaml

echo "=== Waiting for pods ==="
kubectl wait --for=condition=ready pod --all -n online-boutique --timeout=300s \
  || echo "  Some pods still starting — check: kubectl get pods -n online-boutique"

echo "=== Deploying PostgreSQL (for Section 3.2 database monitoring) ==="
kubectl apply -f "$SCRIPT_DIR/postgresql.yaml"

echo "=== Applying frontend Ingress ==="
kubectl apply -f "$SCRIPT_DIR/../nginx-ingress/frontend-ingress.yaml"

echo ""
echo "=== Online Boutique deployed ==="
echo "  Frontend via Ingress: http://boutique.local"
echo "  (Add '127.0.0.1 boutique.local' to /etc/hosts after port-forwarding)"
echo ""
echo "  Direct frontend access:"
echo "    kubectl port-forward svc/frontend 8080:80 -n online-boutique"
echo "    Open: http://localhost:8080"
