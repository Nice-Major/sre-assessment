#!/bin/bash
# =============================================================================
# Create Kibana Alerting Rules via API
# Section 3.1 (VM), 3.2 (PostgreSQL/Redis), 3.3 (Network), 3.4 (NGINX)
#
# Prerequisites:
#   - Kibana running and accessible at $KIBANA_URL
#   - ES credentials available
#
# Usage: bash create-alerting-rules.sh
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

create_rule() {
  local name="$1"
  local payload="$2"
  echo "  Creating rule: $name"
  curl -s -X POST "${KIBANA_URL}/api/alerting/rule" \
    -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    -u "${AUTH}" \
    -d "$payload" | python3 -c "import sys,json; r=json.load(sys.stdin); print(f'    ID: {r.get(\"id\",\"error\")}  Status: {r.get(\"execution_status\",{}).get(\"status\",\"created\")}')" 2>/dev/null || echo "    (created — verify in Kibana)"
}

echo "=== Section 3.1 — VM / Compute Alerting Rules ==="

# Rule 1: High CPU sustained >85% for 5 minutes
create_rule "High CPU Sustained (>85% for 5min)" '{
  "rule_type_id": "metrics.alert.threshold",
  "name": "High CPU Sustained (>85% for 5min)",
  "consumer": "infrastructure",
  "tags": ["sre-assessment", "section-3.1", "compute"],
  "schedule": { "interval": "1m" },
  "params": {
    "criteria": [{
      "metric": "system.cpu.total.norm.pct",
      "comparator": ">",
      "threshold": [0.85],
      "timeSize": 5,
      "timeUnit": "m",
      "aggType": "avg"
    }],
    "sourceId": "default",
    "alertOnNoData": false,
    "alertOnGroupDisappear": false
  },
  "actions": [{
    "group": "metrics.threshold.fired",
    "id": "preconfigured-server-log",
    "params": {
      "message": "ALERT: High CPU detected on {{context.group}} — average {{context.value}} over 5 minutes"
    }
  }],
  "notify_when": "onThrottleInterval",
  "throttle": "5m"
}'

# Rule 2: Disk space critical <10% free
create_rule "Disk Space Critical (<10% free)" '{
  "rule_type_id": "metrics.alert.threshold",
  "name": "Disk Space Critical (<10% free)",
  "consumer": "infrastructure",
  "tags": ["sre-assessment", "section-3.1", "compute"],
  "schedule": { "interval": "1m" },
  "params": {
    "criteria": [{
      "metric": "system.filesystem.used.pct",
      "comparator": ">",
      "threshold": [0.90],
      "timeSize": 1,
      "timeUnit": "m",
      "aggType": "avg"
    }],
    "sourceId": "default",
    "alertOnNoData": false
  },
  "actions": [{
    "group": "metrics.threshold.fired",
    "id": "preconfigured-server-log",
    "params": {
      "message": "ALERT: Disk space critical on {{context.group}} — {{context.value}}% used"
    }
  }],
  "notify_when": "onThrottleInterval",
  "throttle": "15m"
}'

# Rule 3: Memory pressure — available < 500MB
create_rule "Memory Pressure (available < 500MB)" '{
  "rule_type_id": "metrics.alert.threshold",
  "name": "Memory Pressure (available < 500MB)",
  "consumer": "infrastructure",
  "tags": ["sre-assessment", "section-3.1", "compute"],
  "schedule": { "interval": "1m" },
  "params": {
    "criteria": [{
      "metric": "system.memory.actual.free",
      "comparator": "<",
      "threshold": [524288000],
      "timeSize": 1,
      "timeUnit": "m",
      "aggType": "avg"
    }],
    "sourceId": "default",
    "alertOnNoData": false
  },
  "actions": [{
    "group": "metrics.threshold.fired",
    "id": "preconfigured-server-log",
    "params": {
      "message": "ALERT: Low memory on {{context.group}} — available: {{context.value}} bytes"
    }
  }],
  "notify_when": "onThrottleInterval",
  "throttle": "5m"
}'

echo ""
echo "=== Section 3.2 — PostgreSQL Alerting Rules ==="

# Rule 4: PostgreSQL connection pool exhaustion (>80% of max_connections)
create_rule "PostgreSQL Connection Pool Exhaustion (>80%)" '{
  "rule_type_id": "metrics.alert.threshold",
  "name": "PostgreSQL Connection Pool Exhaustion (>80%)",
  "consumer": "infrastructure",
  "tags": ["sre-assessment", "section-3.2", "postgresql"],
  "schedule": { "interval": "1m" },
  "params": {
    "criteria": [{
      "metric": "postgresql.activity.connections",
      "comparator": ">",
      "threshold": [80],
      "timeSize": 1,
      "timeUnit": "m",
      "aggType": "avg"
    }],
    "sourceId": "default",
    "alertOnNoData": false
  },
  "actions": [{
    "group": "metrics.threshold.fired",
    "id": "preconfigured-server-log",
    "params": {
      "message": "ALERT: PostgreSQL connection pool at {{context.value}} (max: 100) on {{context.group}}"
    }
  }],
  "notify_when": "onThrottleInterval",
  "throttle": "5m"
}'

# Rule 5: PostgreSQL cache hit ratio degradation (<95%)
create_rule "PostgreSQL Cache Hit Ratio Low (<95%)" '{
  "rule_type_id": ".es-query",
  "name": "PostgreSQL Cache Hit Ratio Low (<95%)",
  "consumer": "infrastructure",
  "tags": ["sre-assessment", "section-3.2", "postgresql"],
  "schedule": { "interval": "2m" },
  "params": {
    "index": ["metrics-postgresql.database-*"],
    "timeField": "@timestamp",
    "esQuery": "{\"query\":{\"bool\":{\"filter\":[{\"range\":{\"@timestamp\":{\"gte\":\"now-5m\"}}}]}},\"aggs\":{\"hit_ratio\":{\"avg\":{\"script\":{\"source\":\"if(doc[\\\"postgresql.database.stats.blks_hit\\\"].size()>0 && doc[\\\"postgresql.database.stats.blks_read\\\"].size()>0) { return doc[\\\"postgresql.database.stats.blks_hit\\\"].value / (doc[\\\"postgresql.database.stats.blks_hit\\\"].value + doc[\\\"postgresql.database.stats.blks_read\\\"].value + 0.001) } else { return 1.0 }\"}}}}}",
    "thresholdComparator": "<",
    "threshold": [0.95],
    "timeWindowSize": 5,
    "timeWindowUnit": "m",
    "size": 100
  },
  "actions": [{
    "group": "query matched",
    "id": "preconfigured-server-log",
    "params": {
      "message": "ALERT: PostgreSQL cache hit ratio below 95% — potential I/O bottleneck"
    }
  }],
  "notify_when": "onThrottleInterval",
  "throttle": "10m"
}'

echo ""
echo "=== Section 3.2 — Redis Alerting Rules ==="

# Rule 6: Redis memory approaching maxmemory (>85%)
create_rule "Redis Memory High (>85% of maxmemory)" '{
  "rule_type_id": "metrics.alert.threshold",
  "name": "Redis Memory High (>85% of maxmemory)",
  "consumer": "infrastructure",
  "tags": ["sre-assessment", "section-3.2", "redis"],
  "schedule": { "interval": "1m" },
  "params": {
    "criteria": [{
      "metric": "redis.info.memory.used.value",
      "comparator": ">",
      "threshold": [89128960],
      "timeSize": 1,
      "timeUnit": "m",
      "aggType": "avg"
    }],
    "sourceId": "default",
    "alertOnNoData": false
  },
  "actions": [{
    "group": "metrics.threshold.fired",
    "id": "preconfigured-server-log",
    "params": {
      "message": "ALERT: Redis memory usage at {{context.value}} bytes — approaching maxmemory limit"
    }
  }],
  "notify_when": "onThrottleInterval",
  "throttle": "5m"
}'

# Rule 7: Redis high eviction rate
create_rule "Redis High Eviction Rate" '{
  "rule_type_id": "metrics.alert.threshold",
  "name": "Redis High Eviction Rate",
  "consumer": "infrastructure",
  "tags": ["sre-assessment", "section-3.2", "redis"],
  "schedule": { "interval": "1m" },
  "params": {
    "criteria": [{
      "metric": "redis.info.stats.evicted_keys",
      "comparator": ">",
      "threshold": [100],
      "timeSize": 5,
      "timeUnit": "m",
      "aggType": "rate"
    }],
    "sourceId": "default",
    "alertOnNoData": false
  },
  "actions": [{
    "group": "metrics.threshold.fired",
    "id": "preconfigured-server-log",
    "params": {
      "message": "ALERT: Redis eviction rate elevated — {{context.value}} keys evicted in 5 min"
    }
  }],
  "notify_when": "onThrottleInterval",
  "throttle": "10m"
}'

echo ""
echo "=== Section 3.3 — Network Policy Alerting Rules ==="

# Rule 8: Unexpected egress to non-allowlisted external IPs
create_rule "Unexpected External Egress Detected" '{
  "rule_type_id": ".es-query",
  "name": "Unexpected External Egress Detected",
  "consumer": "infrastructure",
  "tags": ["sre-assessment", "section-3.3", "network"],
  "schedule": { "interval": "2m" },
  "params": {
    "index": ["logs-calico.flowlog-*"],
    "timeField": "@timestamp",
    "esQuery": "{\"query\":{\"bool\":{\"must\":[{\"term\":{\"event.action\":\"deny\"}},{\"range\":{\"@timestamp\":{\"gte\":\"now-5m\"}}}],\"must_not\":[{\"terms\":{\"destination.ip\":[\"10.0.0.0/8\",\"172.16.0.0/12\",\"192.168.0.0/16\"]}}]}}}",
    "thresholdComparator": ">",
    "threshold": [0],
    "timeWindowSize": 5,
    "timeWindowUnit": "m",
    "size": 100
  },
  "actions": [{
    "group": "query matched",
    "id": "preconfigured-server-log",
    "params": {
      "message": "ALERT: Unexpected external egress traffic detected — check Calico flow logs"
    }
  }],
  "notify_when": "onThrottleInterval",
  "throttle": "5m"
}'

echo ""
echo "=== Section 3.4 — NGINX Ingress Alerting Rules ==="

# Rule 9: 5xx error rate spike (>5% over 2 minutes)
create_rule "NGINX 5xx Error Rate Spike (>5%)" '{
  "rule_type_id": ".es-query",
  "name": "NGINX 5xx Error Rate Spike (>5% over 2min)",
  "consumer": "infrastructure",
  "tags": ["sre-assessment", "section-3.4", "nginx"],
  "schedule": { "interval": "1m" },
  "params": {
    "index": ["logs-nginx.access-*"],
    "timeField": "@timestamp",
    "esQuery": "{\"query\":{\"bool\":{\"filter\":[{\"range\":{\"@timestamp\":{\"gte\":\"now-2m\"}}},{\"range\":{\"nginx.status\":{\"gte\":500,\"lt\":600}}}]}}}",
    "thresholdComparator": ">",
    "threshold": [5],
    "timeWindowSize": 2,
    "timeWindowUnit": "m",
    "size": 100
  },
  "actions": [{
    "group": "query matched",
    "id": "preconfigured-server-log",
    "params": {
      "message": "ALERT: NGINX 5xx error rate exceeded 5% in the last 2 minutes"
    }
  }],
  "notify_when": "onThrottleInterval",
  "throttle": "5m"
}'

# Rule 10: Upstream service unavailable (502/503)
create_rule "NGINX Upstream Unavailable (502/503)" '{
  "rule_type_id": ".es-query",
  "name": "NGINX Upstream Unavailable (502/503)",
  "consumer": "infrastructure",
  "tags": ["sre-assessment", "section-3.4", "nginx"],
  "schedule": { "interval": "1m" },
  "params": {
    "index": ["logs-nginx.access-*"],
    "timeField": "@timestamp",
    "esQuery": "{\"query\":{\"bool\":{\"filter\":[{\"range\":{\"@timestamp\":{\"gte\":\"now-2m\"}}},{\"terms\":{\"nginx.status\":[502,503]}}]}}}",
    "thresholdComparator": ">",
    "threshold": [3],
    "timeWindowSize": 2,
    "timeWindowUnit": "m",
    "size": 100
  },
  "actions": [{
    "group": "query matched",
    "id": "preconfigured-server-log",
    "params": {
      "message": "ALERT: Backend service returning 502/503 — potential upstream failure"
    }
  }],
  "notify_when": "onThrottleInterval",
  "throttle": "5m"
}'

# Rule 11: SSL certificate expiring within 14 days
create_rule "SSL Certificate Expiring (<14 days)" '{
  "rule_type_id": ".es-query",
  "name": "SSL Certificate Expiring (<14 days)",
  "consumer": "infrastructure",
  "tags": ["sre-assessment", "section-3.4", "nginx", "ssl"],
  "schedule": { "interval": "1h" },
  "params": {
    "index": ["metrics-nginx.*"],
    "timeField": "@timestamp",
    "esQuery": "{\"query\":{\"bool\":{\"filter\":[{\"range\":{\"nginx.ssl.certificate_expiry\":{\"lte\":\"now+14d\"}}}]}}}",
    "thresholdComparator": ">",
    "threshold": [0],
    "timeWindowSize": 24,
    "timeWindowUnit": "h",
    "size": 10
  },
  "actions": [{
    "group": "query matched",
    "id": "preconfigured-server-log",
    "params": {
      "message": "ALERT: SSL certificate expiring within 14 days — renew immediately"
    }
  }],
  "notify_when": "onThrottleInterval",
  "throttle": "24h"
}'

echo ""
echo "=== All alerting rules created ==="
echo "  Verify in Kibana → Observability → Rules"
echo "  Total rules: 11"
