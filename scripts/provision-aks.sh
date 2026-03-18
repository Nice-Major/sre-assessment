#!/bin/bash
# =============================================================================
# SRE Assessment — Azure AKS Cluster Provisioning
#
# Creates a cost-optimized AKS cluster for the assessment:
#   - 2x Standard_D4s_v3 nodes (4 vCPU, 16 GB RAM each)
#   - Calico network policy plugin
#   - Auto-configures kubectl context
#
# Estimated cost: ~$0.40/hour ($3-5 for assessment duration)
# Cleanup: az group delete --name sre-assessment-rg --yes --no-wait
# =============================================================================
set -euo pipefail

# ── Configuration ──
RESOURCE_GROUP="sre-assessment-rg"
CLUSTER_NAME="sre-assessment-aks"
LOCATION="northeurope"         # Alternative region with AKS free tier availability
NODE_COUNT=2
NODE_SIZE="Standard_D4ads_v6"  # 4 vCPU, 16 GB RAM — good balance
K8S_VERSION="1.32"

echo "╔════════════════════════════════════════════════════════╗"
echo "║  SRE Assessment — AKS Cluster Provisioning             ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "  Resource Group : $RESOURCE_GROUP"
echo "  Cluster        : $CLUSTER_NAME"
echo "  Location       : $LOCATION"
echo "  Nodes          : $NODE_COUNT x $NODE_SIZE (16 GB RAM each)"
echo "  Network Policy : Calico"
echo ""

# ── Step 1: Create Resource Group ──
echo "━━━ Step 1/4: Creating Resource Group ━━━"
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output table

# ── Step 2: Create AKS Cluster ──
echo ""
echo "━━━ Step 2/4: Creating AKS Cluster (5-8 minutes) ━━━"
az aks create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --location "$LOCATION" \
  --node-count "$NODE_COUNT" \
  --node-vm-size "$NODE_SIZE" \
  --kubernetes-version "$K8S_VERSION" \
  --network-plugin azure \
  --network-policy calico \
  --generate-ssh-keys \
  --enable-managed-identity \
  --tier free \
  --output table

# ── Step 3: Get Credentials ──
echo ""
echo "━━━ Step 3/4: Configuring kubectl ━━━"
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --overwrite-existing

# ── Step 4: Verify ──
echo ""
echo "━━━ Step 4/4: Verifying Cluster ━━━"
kubectl get nodes -o wide
echo ""
kubectl cluster-info

# ── Create Namespaces ──
echo ""
echo "━━━ Creating Namespaces ━━━"
kubectl create namespace elastic          2>/dev/null || true
kubectl create namespace otel-system      2>/dev/null || true
kubectl create namespace online-boutique  2>/dev/null || true
kubectl create namespace ingress-nginx    2>/dev/null || true
kubectl create namespace monitoring       2>/dev/null || true

# ── Add Helm Repos ──
echo ""
echo "━━━ Adding Helm Repos ━━━"
helm repo add elastic         https://helm.elastic.co          2>/dev/null || true
helm repo add open-telemetry  https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo add ingress-nginx   https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo add bitnami         https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update

echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║  AKS Cluster Ready!                                    ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "  Nodes: $NODE_COUNT x $NODE_SIZE"
echo "  Total: $((NODE_COUNT * 4)) vCPUs, $((NODE_COUNT * 16)) GB RAM"
echo "  Network Policy: Calico (for Section 3.3)"
echo ""
echo "  Next: Deploy the full stack:"
echo "    bash kubernetes/elastic-stack/deploy-elastic-stack.sh"
echo "    bash kubernetes/nginx-ingress/deploy-nginx-ingress.sh"
echo "    bash kubernetes/online-boutique/deploy-online-boutique.sh"
echo "    bash otel-collector/deploy-otel-collector.sh"
echo ""
echo "  COST WARNING: Delete when done!"
echo "    az group delete --name $RESOURCE_GROUP --yes --no-wait"
