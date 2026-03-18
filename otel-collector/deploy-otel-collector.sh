#!/bin/bash
# =============================================================================
# Deploy OTel Collector — Agent (DaemonSet) + Gateway (Deployment)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Deploying OTel Collector Gateway ==="
helm install otel-gateway open-telemetry/opentelemetry-collector \
  -f "$SCRIPT_DIR/values-gateway.yaml" \
  -n otel-system --create-namespace \
  --wait

echo "=== Deploying OTel Collector Agent (DaemonSet) ==="
helm install otel-agent open-telemetry/opentelemetry-collector \
  -f "$SCRIPT_DIR/values-agent.yaml" \
  -n otel-system \
  --wait

echo "=== Verifying OTel Collectors ==="
kubectl get pods -n otel-system
echo ""
echo "=== OTel Collector deployed ==="
echo "  Gateway: otel-gateway-opentelemetry-collector.otel-system.svc.cluster.local:4317"
echo "  Agent (DaemonSet): accessible via node hostPort :4317"
echo ""
echo "  Check zpages: kubectl port-forward svc/otel-gateway-opentelemetry-collector 55679:55679 -n otel-system"
echo "  Open: http://localhost:55679/debug/tracez"
