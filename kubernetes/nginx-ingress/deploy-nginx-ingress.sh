#!/bin/bash
# =============================================================================
# Deploy NGINX Ingress Controller with metrics + structured JSON logs
# =============================================================================
set -euo pipefail

echo "=== Installing NGINX Ingress Controller ==="
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.metrics.enabled=true \
  --set controller.metrics.port=10254 \
  --set controller.podAnnotations."prometheus\.io/scrape"="true" \
  --set controller.podAnnotations."prometheus\.io/port"="10254" \
  --set controller.config.log-format-upstream='{"time":"$time_iso8601","remote_addr":"$remote_addr","request_method":"$request_method","request_uri":"$request_uri","status":"$status","body_bytes_sent":"$body_bytes_sent","request_time":"$request_time","upstream_response_time":"$upstream_response_time","upstream_addr":"$upstream_addr","http_user_agent":"$http_user_agent","http_referer":"$http_referer","host":"$host","ssl_protocol":"$ssl_protocol","request_length":"$request_length"}' \
  --set controller.config.enable-opentelemetry="true" \
  --wait

echo "=== Verifying NGINX Ingress ==="
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=ingress-nginx \
  -n ingress-nginx --timeout=120s

echo "=== NGINX Ingress Controller deployed ==="
echo "  Metrics endpoint: :10254/metrics"
echo "  Access logs: structured JSON format"
