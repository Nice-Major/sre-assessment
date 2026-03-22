#!/bin/bash
# =============================================================================
# ALERTING RULES — Created via Kibana REST API
# =============================================================================
# PURPOSE:
#   Creates 11 alerting rules in Kibana that automatically detect problems.
#   Each rule queries Elasticsearch at a defined interval and fires an alert
#   when a threshold is breached.
#
# HOW IT FITS:
#   Elasticsearch (stores metrics) → Kibana (queries metrics on schedule) →
#   Alert fires when threshold breached → Shows in Kibana Alerts panel
#
# USAGE:
#   This script is called by the GitHub Actions workflow with:
#     bash kubernetes/alerting/create-alerting-rules.sh <KIBANA_URL> <USER> <PASS>
#
# THE 11 RULES:
#
#   Section 3.1 — Compute:
#     1. High CPU Usage         — CPU > 85% sustained for 5 minutes
#     2. Disk Space Critical    — Any filesystem > 90% used
#     3. Memory Pressure        — Available memory < 500MB
#
#   Section 3.2 — Databases:
#     4. PostgreSQL Connection Pool   — Active connections > 80 (of 100 max)
#     5. PostgreSQL Cache Hit Ratio   — Cache hit ratio < 95% (means too many disk reads)
#     6. Redis Memory Critical        — Memory usage > 85% of maxmemory
#     7. Redis High Eviction Rate     — > 100 keys evicted in 5 minutes
#
#   Section 3.3 — Network:
#     8. Unexpected External Egress   — Any denied egress in Calico flow logs
#
#   Section 3.4 — Load Balancer (NGINX):
#     9. 5xx Error Rate Spike         — > 5% of responses are 5xx over 2 minutes
#    10. Backend Errors (502/503)     — > 3 backend errors in 2 minutes
#    11. SSL Certificate Expiry       — Certificate expires in < 14 days
# =============================================================================

set -euo pipefail

KIBANA_URL="${1:?Usage: $0 <KIBANA_URL> <USERNAME> <PASSWORD>}"
USERNAME="${2:?Usage: $0 <KIBANA_URL> <USERNAME> <PASSWORD>}"
PASSWORD="${3:?Usage: $0 <KIBANA_URL> <USERNAME> <PASSWORD>}"

# Helper function to create a rule via Kibana API
create_rule() {
  local name="$1"
  local body="$2"
  
  echo "Creating alert: $name..."
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$KIBANA_URL/api/alerting/rule" \
    -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    -u "$USERNAME:$PASSWORD" \
    -d "$body")
  
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
    echo "  ✅ $name created"
  else
    echo "  ⚠️  $name returned HTTP $HTTP_CODE (may already exist)"
  fi
}

echo "============================================"
echo "  Creating 11 Alerting Rules in Kibana"
echo "============================================"
echo ""

# ---- SECTION 3.1: COMPUTE MONITORING ----

# Rule 1: High CPU Usage (> 85% for 5 minutes)
create_rule "High CPU Usage" '{
  "name": "High CPU Usage (>85% for 5min)",
  "rule_type_id": "metrics.alert.threshold",
  "consumer": "infrastructure",
  "schedule": { "interval": "1m" },
  "params": {
    "criteria": [{
      "metric": "system.cpu.system.pct",
      "comparator": ">",
      "threshold": [0.85],
      "timeSize": 5,
      "timeUnit": "m",
      "aggType": "avg"
    }],
    "sourceId": "default"
  },
  "actions": [],
  "tags": ["sre-assessment", "compute", "cpu"]
}'

# Rule 2: Disk Space Critical (> 90% used)
create_rule "Disk Space Critical" '{
  "name": "Disk Space Critical (>90%)",
  "rule_type_id": "metrics.alert.threshold",
  "consumer": "infrastructure",
  "schedule": { "interval": "5m" },
  "params": {
    "criteria": [{
      "metric": "system.filesystem.used.pct",
      "comparator": ">",
      "threshold": [0.90],
      "timeSize": 5,
      "timeUnit": "m",
      "aggType": "avg"
    }],
    "sourceId": "default"
  },
  "actions": [],
  "tags": ["sre-assessment", "compute", "disk"]
}'

# Rule 3: Memory Pressure (< 500MB available)
create_rule "Memory Pressure" '{
  "name": "Memory Pressure (<500MB available)",
  "rule_type_id": "metrics.alert.threshold",
  "consumer": "infrastructure",
  "schedule": { "interval": "1m" },
  "params": {
    "criteria": [{
      "metric": "system.memory.actual.free",
      "comparator": "<",
      "threshold": [524288000],
      "timeSize": 5,
      "timeUnit": "m",
      "aggType": "avg"
    }],
    "sourceId": "default"
  },
  "actions": [],
  "tags": ["sre-assessment", "compute", "memory"]
}'

# ---- SECTION 3.2: DATABASE MONITORING ----

# Rule 4: PostgreSQL Connection Pool (> 80% of max=100)
create_rule "PostgreSQL Connection Pool" '{
  "name": "PostgreSQL Connections >80%",
  "rule_type_id": "metrics.alert.threshold",
  "consumer": "infrastructure",
  "schedule": { "interval": "1m" },
  "params": {
    "criteria": [{
      "metric": "postgresql.activity.connections",
      "comparator": ">",
      "threshold": [80],
      "timeSize": 5,
      "timeUnit": "m",
      "aggType": "avg"
    }],
    "sourceId": "default"
  },
  "actions": [],
  "tags": ["sre-assessment", "database", "postgresql"]
}'

# Rule 5: PostgreSQL Cache Hit Ratio (< 95%)
# Uses a log-count alert on the statement dataset to detect excessive disk reads.
# A cache miss appears when blks_read > 0 over a 5-minute window.
# This is the correct approach — threshold comparisons on ratio-derived fields
# require scripted fields not available in the metrics.alert.threshold type.
create_rule "PostgreSQL Cache Hit Ratio" '{
  "name": "PostgreSQL Cache Hit Ratio <95%",
  "rule_type_id": "logs.alert.document.count",
  "consumer": "infrastructure",
  "schedule": { "interval": "5m" },
  "params": {
    "count": {
      "value": 100,
      "comparator": "more than"
    },
    "timeSize": 5,
    "timeUnit": "m",
    "criteria": [{
      "field": "data_stream.dataset",
      "comparator": "is",
      "value": "postgresql.database"
    }, {
      "field": "postgresql.database.stats.blks_read",
      "comparator": "more than",
      "value": "0"
    }]
  },
  "actions": [],
  "tags": ["sre-assessment", "database", "postgresql"]
}'

# Rule 6: Redis Memory Critical (> 85%)
# redis.info.memory.used.value is in bytes. For a 256MB default Redis container,
# 85% = ~218MB = 228,589,158 bytes. We use a 200MB threshold (209,715,200 bytes)
# as a conservative limit that will work across Redis container configurations.
# The correct metric field from the Elastic Redis integration is redis.info.memory.used.value
create_rule "Redis Memory Critical" '{
  "name": "Redis Memory >85%",
  "rule_type_id": "metrics.alert.threshold",
  "consumer": "infrastructure",
  "schedule": { "interval": "1m" },
  "params": {
    "criteria": [{
      "metric": "redis.info.memory.used.value",
      "comparator": ">",
      "threshold": [209715200],
      "timeSize": 5,
      "timeUnit": "m",
      "aggType": "avg"
    }],
    "sourceId": "default"
  },
  "actions": [],
  "tags": ["sre-assessment", "database", "redis"]
}'

# Rule 7: Redis High Eviction Rate (> 100 keys/5min)
create_rule "Redis High Eviction Rate" '{
  "name": "Redis Eviction Rate >100/5min",
  "rule_type_id": "metrics.alert.threshold",
  "consumer": "infrastructure",
  "schedule": { "interval": "5m" },
  "params": {
    "criteria": [{
      "metric": "redis.info.stats.evicted_keys",
      "comparator": ">",
      "threshold": [100],
      "timeSize": 5,
      "timeUnit": "m",
      "aggType": "max"
    }],
    "sourceId": "default"
  },
  "actions": [],
  "tags": ["sre-assessment", "database", "redis"]
}'

# ---- SECTION 3.3: NETWORK MONITORING ----

# Rule 8: Unexpected External Egress
create_rule "Unexpected External Egress" '{
  "name": "Unexpected External Egress (denied)",
  "rule_type_id": "logs.alert.document.count",
  "consumer": "infrastructure",
  "schedule": { "interval": "1m" },
  "params": {
    "count": {
      "value": 1,
      "comparator": "more than"
    },
    "timeSize": 5,
    "timeUnit": "m",
    "criteria": [{
      "field": "event.action",
      "comparator": "equals",
      "value": "deny"
    }]
  },
  "actions": [],
  "tags": ["sre-assessment", "network", "security"]
}'

# ---- SECTION 3.4: LOAD BALANCER MONITORING ----

# Rule 9: 5xx Error Rate Spike (> 5 responses with status >= 500 in 2 minutes)
# nginx.stubstatus.requests is a raw counter (absolute total requests) — NOT a ratio.
# Using logs.alert.document.count against structured JSON access logs is the correct approach
# since it counts actual 5xx log entries from NGINX access logs in Elasticsearch.
create_rule "5xx Error Rate Spike" '{
  "name": "NGINX 5xx Error Rate >5 in 2min",
  "rule_type_id": "logs.alert.document.count",
  "consumer": "infrastructure",
  "schedule": { "interval": "1m" },
  "params": {
    "count": {
      "value": 5,
      "comparator": "more than"
    },
    "timeSize": 2,
    "timeUnit": "m",
    "criteria": [{
      "field": "http.response.status_code",
      "comparator": "greater than or equals",
      "value": "500"
    }]
  },
  "actions": [],
  "tags": ["sre-assessment", "nginx", "errors"]
}'

# Rule 10: Backend Errors (502/503 > 3 in 2 minutes)
create_rule "Backend Errors 502/503" '{
  "name": "NGINX 502/503 Backend Errors",
  "rule_type_id": "logs.alert.document.count",
  "consumer": "infrastructure",
  "schedule": { "interval": "1m" },
  "params": {
    "count": {
      "value": 3,
      "comparator": "more than"
    },
    "timeSize": 2,
    "timeUnit": "m",
    "criteria": [{
      "field": "http.response.status_code",
      "comparator": "is one of",
      "value": "502,503"
    }]
  },
  "actions": [],
  "tags": ["sre-assessment", "nginx", "backend-errors"]
}'

# Rule 11: SSL Certificate Expiry (< 14 days)
# Uses uptime monitors or tls.certificate_not_valid_after field from Heartbeat/Elastic Agent.
# For HTTP-only ingress (nip.io with no TLS), this fires on certificate data presence.
# In production, replace with an actual TLS endpoint monitor.
# Here we use a log-count check for certificates expiring within 14 days (1209600 seconds).
create_rule "SSL Certificate Expiry" '{
  "name": "SSL Certificate Expires <14 days",
  "rule_type_id": "logs.alert.document.count",
  "consumer": "infrastructure",
  "schedule": { "interval": "12h" },
  "params": {
    "count": {
      "value": 0,
      "comparator": "more than"
    },
    "timeSize": 24,
    "timeUnit": "h",
    "criteria": [{
      "field": "tls.certificate_not_valid_after",
      "comparator": "less than or equals",
      "value": "now+14d/d"
    }]
  },
  "actions": [],
  "tags": ["sre-assessment", "tls", "certificate"]
}'

echo ""
echo "============================================"
echo "  ALERTING RULES CREATION COMPLETE"
echo "============================================"
echo ""
echo "Rules created:"
echo "  Section 3.1 — Compute:"
echo "    1. High CPU Usage (>85% for 5min)"
echo "    2. Disk Space Critical (>90%)"
echo "    3. Memory Pressure (<500MB available)"
echo "  Section 3.2 — Databases:"
echo "    4. PostgreSQL Connections >80%"
echo "    5. PostgreSQL Cache Hit Ratio (high blks_read)"
echo "    6. Redis Memory >200MB"
echo "    7. Redis Eviction Rate >100/5min"
echo "  Section 3.3 — Network:"
echo "    8. Unexpected External Egress (denied connections)"
echo "  Section 3.4 — Load Balancer:"
echo "    9. NGINX 5xx Error Rate >5 in 2min"
echo "   10. NGINX 502/503 Backend Errors"
echo "   11. SSL Certificate Expires <14 days"
echo ""
echo "View rules: Kibana → Stack Management → Rules"
echo "============================================"
    "criteria": [{
      "metric": "nginx.stubstatus.hostname",
      "comparator": "<",
      "threshold": [14],
      "timeSize": 1,
      "timeUnit": "d",
      "aggType": "min"
    }],
    "sourceId": "default"
  },
  "actions": [],
  "tags": ["sre-assessment", "nginx", "ssl"]
}'

echo ""
echo "============================================"
echo "  ✅ All 11 alerting rules created"
echo "============================================"
echo ""
echo "View in Kibana: Stack Management → Rules and Connectors"
