#!/bin/bash
# =============================================================================
# Deploy Elastic Stack (ECK) into the cluster
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Installing ECK Operator ==="
helm install elastic-operator elastic/eck-operator \
  --namespace elastic-system \
  --create-namespace \
  --set managedNamespaces='{elastic}' \
  --wait

echo "=== Waiting for ECK operator to be ready ==="
kubectl wait --for=condition=ready pod -l control-plane=elastic-operator \
  -n elastic-system --timeout=120s

echo "=== Deploying Elasticsearch ==="
kubectl apply -f "$SCRIPT_DIR/elasticsearch.yaml"
echo "  Waiting for Elasticsearch (this may take 2-3 minutes)..."
kubectl wait --for=condition=ready pod -l elasticsearch.k8s.elastic.co/cluster-name=elasticsearch \
  -n elastic --timeout=300s || echo "  Still starting — check: kubectl get elasticsearch -n elastic"

echo "=== Deploying Kibana ==="
kubectl apply -f "$SCRIPT_DIR/kibana.yaml"

echo "=== Deploying APM Server ==="
kubectl apply -f "$SCRIPT_DIR/apm-server.yaml"

echo "=== Deploying Fleet Server ==="
kubectl apply -f "$SCRIPT_DIR/fleet-server.yaml"

echo ""
echo "=== Retrieving credentials ==="
ES_PASSWORD=$(kubectl get secret elasticsearch-es-elastic-user -n elastic -o jsonpath='{.data.elastic}' | base64 -d)
echo "  Elasticsearch URL : http://elasticsearch-es-http.elastic.svc.cluster.local:9200"
echo "  Kibana URL        : http://kibana-kb-http.elastic.svc.cluster.local:5601"
echo "  APM Server URL    : http://apm-server-apm-http.elastic.svc.cluster.local:8200"
echo "  Username          : elastic"
echo "  Password          : $ES_PASSWORD"
echo ""
echo "  To access Kibana via Ingress (after Ingress is deployed):"
echo "    http://kibana.<INGRESS_IP>.nip.io"
echo ""
echo "  APM Secret Token  : assessment-secret-token"
