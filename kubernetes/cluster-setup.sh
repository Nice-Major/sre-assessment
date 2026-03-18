#!/bin/bash
# =============================================================================
# SRE Assessment — Cluster Bootstrap Script
# Creates a multi-node minikube cluster with required add-ons
# =============================================================================
set -euo pipefail

PROFILE="sre-assessment"
NODES=3
CPUS=4
MEMORY=8192       # MB per node
DISK="50g"
K8S_VERSION="v1.29.2"

echo "=== Creating minikube cluster: $PROFILE ==="
minikube start \
  --profile="$PROFILE" \
  --nodes="$NODES" \
  --cpus="$CPUS" \
  --memory="$MEMORY" \
  --disk-size="$DISK" \
  --kubernetes-version="$K8S_VERSION" \
  --driver=docker \
  --cni=calico \
  --addons=metrics-server

echo "=== Verifying nodes ==="
kubectl get nodes -o wide

echo "=== Creating namespaces ==="
kubectl create namespace elastic          2>/dev/null || true
kubectl create namespace otel-system      2>/dev/null || true
kubectl create namespace online-boutique  2>/dev/null || true
kubectl create namespace ingress-nginx    2>/dev/null || true
kubectl create namespace monitoring       2>/dev/null || true

echo "=== Adding Helm repos ==="
helm repo add elastic         https://helm.elastic.co
helm repo add open-telemetry  https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo add ingress-nginx   https://kubernetes.github.io/ingress-nginx
helm repo add bitnami         https://charts.bitnami.com/bitnami
helm repo update

echo "=== Cluster ready ==="
echo "Next steps:"
echo "  1. Run: bash kubernetes/deploy-elastic-stack.sh"
echo "  2. Run: bash kubernetes/deploy-online-boutique.sh"
echo "  3. Run: bash kubernetes/deploy-nginx-ingress.sh"
