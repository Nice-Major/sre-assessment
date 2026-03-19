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
echo "  Frontend via Ingress: http://<INGRESS_IP>"
echo "  (Get IP: kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
