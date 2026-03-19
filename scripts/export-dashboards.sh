#!/bin/bash
# =============================================================================
# Export Kibana Dashboards as NDJSON Saved Objects
# Run this AFTER dashboards have been created in Kibana.
#
# Usage: bash scripts/export-dashboards.sh
# =============================================================================
set -euo pipefail

# Auto-detect Ingress IP for Kibana URL (no port-forwarding needed)
INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [ -n "$INGRESS_IP" ]; then
  KIBANA_URL="${KIBANA_URL:-http://kibana.${INGRESS_IP}.nip.io}"
else
  KIBANA_URL="${KIBANA_URL:-https://localhost:5601}"
  echo "WARNING: No Ingress IP found. Falling back to localhost (requires port-forward)."
fi
ES_PASSWORD=$(kubectl get secret elasticsearch-es-elastic-user -n elastic -o jsonpath='{.data.elastic}' | base64 -d)
AUTH="elastic:${ES_PASSWORD}"
DASHBOARD_DIR="$(cd "$(dirname "$0")/../dashboards" && pwd)"

mkdir -p "$DASHBOARD_DIR"

echo "=== Exporting Kibana Dashboards ==="

# Export all dashboards tagged with 'sre-assessment'
# This captures dashboards + their dependent visualizations, index patterns, etc.

# Dashboard 1: Service Health Overview
echo "  Exporting: Service Health Overview..."
curl -s -X POST "${KIBANA_URL}/api/saved_objects/_export" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -u "${AUTH}" \
  -d '{"type": "dashboard", "search": "Service Health Overview", "includeReferencesDeep": true}' \
  > "${DASHBOARD_DIR}/service-health.ndjson"
echo "    → ${DASHBOARD_DIR}/service-health.ndjson"

# Dashboard 2: RUM / Frontend Performance
echo "  Exporting: RUM Performance..."
curl -s -X POST "${KIBANA_URL}/api/saved_objects/_export" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -u "${AUTH}" \
  -d '{"type": "dashboard", "search": "RUM Performance", "includeReferencesDeep": true}' \
  > "${DASHBOARD_DIR}/rum-performance.ndjson"
echo "    → ${DASHBOARD_DIR}/rum-performance.ndjson"

# Dashboard 3: Business Transaction Monitoring
echo "  Exporting: Business Transactions..."
curl -s -X POST "${KIBANA_URL}/api/saved_objects/_export" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -u "${AUTH}" \
  -d '{"type": "dashboard", "search": "Business Transaction", "includeReferencesDeep": true}' \
  > "${DASHBOARD_DIR}/business-transactions.ndjson"
echo "    → ${DASHBOARD_DIR}/business-transactions.ndjson"

# Export alerting rules
echo "  Exporting: Alerting Rules..."
curl -s -X POST "${KIBANA_URL}/api/saved_objects/_export" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -u "${AUTH}" \
  -d '{"type": "alert", "includeReferencesDeep": true}' \
  > "${DASHBOARD_DIR}/../infrastructure/alerting-rules/alerting-rules.ndjson"
echo "    → infrastructure/alerting-rules/alerting-rules.ndjson"

echo ""
echo "=== Export complete ==="
echo "  All NDJSON files are in: ${DASHBOARD_DIR}/"
echo "  To re-import: POST /api/saved_objects/_import with the NDJSON file"
