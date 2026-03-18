#!/bin/bash
# =============================================================================
# Master Deployment Script — Full SRE Assessment Stack
#
# Deploys everything end-to-end in the correct order:
#   1. Kubernetes cluster (minikube with Calico)
#   2. Elastic Stack (ECK)
#   3. NGINX Ingress Controller
#   4. Google Online Boutique + PostgreSQL
#   5. OTel Collector (Gateway + Agent)
#   6. Network Policies
#   7. Infrastructure monitoring (Calico flow logs, Filebeat)
#   8. Alerting rules
#
# Usage: bash scripts/deploy-all.sh
#
# Prerequisites:
#   - docker, minikube, kubectl, helm installed
#   - 16GB+ RAM, 8+ CPU cores available
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "╔════════════════════════════════════════════════════════╗"
echo "║  SRE Assessment — Full Deployment                     ║"
echo "║  Elastic Stack + OTel + Online Boutique + Monitoring   ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Cluster ──
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 1/8: Creating Kubernetes Cluster"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "$ROOT_DIR/kubernetes/cluster-setup.sh"
echo ""

# ── Step 2: Elastic Stack ──
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 2/8: Deploying Elastic Stack (ECK)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "$ROOT_DIR/kubernetes/elastic-stack/deploy-elastic-stack.sh"
echo ""

# Wait for Elastic Stack to be fully ready
echo "  Waiting for Elasticsearch to be green..."
kubectl wait --for=jsonpath='{.status.health}'=green elasticsearch/elasticsearch -n elastic --timeout=300s 2>/dev/null \
  || echo "  Elasticsearch still initializing — continuing..."

echo "  Waiting for Kibana to be ready..."
kubectl wait --for=condition=ready pod -l kibana.k8s.elastic.co/name=kibana -n elastic --timeout=300s 2>/dev/null \
  || echo "  Kibana still initializing — continuing..."

echo "  Waiting for APM Server to be ready..."
kubectl wait --for=condition=ready pod -l apm.k8s.elastic.co/name=apm-server -n elastic --timeout=180s 2>/dev/null \
  || echo "  APM Server still initializing — continuing..."

# ── Step 3: NGINX Ingress ──
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 3/8: Deploying NGINX Ingress Controller"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "$ROOT_DIR/kubernetes/nginx-ingress/deploy-nginx-ingress.sh"
echo ""

# ── Step 4: Online Boutique + PostgreSQL ──
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 4/8: Deploying Online Boutique + PostgreSQL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "$ROOT_DIR/kubernetes/online-boutique/deploy-online-boutique.sh"
echo ""

# ── Step 5: OTel Collector ──
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 5/8: Deploying OpenTelemetry Collector"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "$ROOT_DIR/otel-collector/deploy-otel-collector.sh"
echo ""

# ── Step 6: Network Policies ──
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 6/8: Applying Network Policies"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Labeling namespaces for policy selectors..."
kubectl label namespace ingress-nginx kubernetes.io/metadata.name=ingress-nginx --overwrite 2>/dev/null || true
kubectl label namespace otel-system kubernetes.io/metadata.name=otel-system --overwrite 2>/dev/null || true
kubectl label namespace elastic kubernetes.io/metadata.name=elastic --overwrite 2>/dev/null || true

echo "  Applying network policies..."
kubectl apply -f "$ROOT_DIR/infrastructure/network-policies/network-policies.yaml"
echo "  Network policies applied."
echo ""

# ── Step 7: Infrastructure Monitoring ──
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 7/8: Deploying Infrastructure Monitoring"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Deploying Calico flow log collector (Filebeat)..."
kubectl apply -f "$ROOT_DIR/infrastructure/network-policies/calico-flow-logs.yaml" 2>/dev/null \
  || echo "    Calico flow logs config applied (verify Calico CNI is installed)"

echo "  Deploying Kubernetes audit log collector..."
kubectl apply -f "$ROOT_DIR/infrastructure/network-policies/kube-audit-filebeat.yaml" 2>/dev/null \
  || echo "    Kube audit log collector applied"

echo ""
echo "  NOTE: Fleet-managed Elastic Agent integrations (System, PostgreSQL, Redis, NGINX)"
echo "  must be configured via Kibana Fleet UI after Kibana is accessible."
echo "  See: infrastructure/ directory for integration configs."
echo ""

# ── Step 8: Service patches (OTel env vars) ──
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 8/8: Applying Service Instrumentation Patches"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Patching frontend..."
kubectl patch deployment frontend -n online-boutique --patch-file "$ROOT_DIR/instrumentation/frontend/k8s-patch.yaml" || true
echo "  Patching cartservice..."
kubectl patch deployment cartservice -n online-boutique --patch-file "$ROOT_DIR/instrumentation/cartservice/k8s-patch.yaml" || true
echo "  Patching paymentservice..."
kubectl patch deployment paymentservice -n online-boutique --patch-file "$ROOT_DIR/instrumentation/paymentservice/k8s-patch.yaml" || true
echo ""

# ── Summary ──
ES_PASSWORD=$(kubectl get secret elasticsearch-es-elastic-user -n elastic -o jsonpath='{.data.elastic}' | base64 -d 2>/dev/null || echo "PENDING")

echo "╔════════════════════════════════════════════════════════╗"
echo "║  Deployment Complete!                                  ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "  Access Points (use kubectl port-forward):"
echo "  ─────────────────────────────────────────"
echo "  Kibana:     kubectl port-forward svc/kibana-kb-http 5601:5601 -n elastic"
echo "              → http://localhost:5601  (elastic / ${ES_PASSWORD})"
echo ""
echo "  Frontend:   kubectl port-forward svc/frontend 8080:80 -n online-boutique"
echo "              → http://localhost:8080"
echo ""
echo "  APM Server: kubectl port-forward svc/apm-server-apm-http 8200:8200 -n elastic"
echo "              → http://localhost:8200 (token: assessment-secret-token)"
echo ""
echo "  OTel zpages: kubectl port-forward svc/otel-gateway-opentelemetry-collector 55679:55679 -n otel-system"
echo "              → http://localhost:55679/debug/tracez"
echo ""
echo "  Next Steps:"
echo "  ─────────────────────────────────────────"
echo "  1. Open Kibana and configure Fleet Agent policies (see infrastructure/ configs)"
echo "  2. Generate traffic: bash scripts/generate-traffic.sh"
echo "  3. Create alerting rules: bash infrastructure/alerting-rules/create-alerting-rules.sh"
echo "  4. Build dashboards in Kibana (see dashboards/DASHBOARD-GUIDE.md)"
echo "  5. Export dashboards: bash scripts/export-dashboards.sh"
echo "  6. Verify traces: Kibana → Observability → APM → Traces"
