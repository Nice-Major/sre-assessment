# =============================================================================
# Kibana Dashboard Creation Guide
# Section 2.2 — Operational Dashboards
#
# These dashboards must be created in Kibana's UI and then exported as NDJSON.
# This file documents the exact panels, data sources, and visualization types.
# =============================================================================

## Prerequisites
Before creating dashboards:
1. Verify data is flowing: Kibana → Observability → APM → Services (should show instrumented services)
2. Verify metrics indices: Kibana → Stack Management → Data Views → create data views for:
   - `traces-apm*` (APM transaction data)
   - `metrics-*` (all metrics including custom OTel metrics)
   - `logs-*` (all log data)
   - `rum-*` or `traces-apm-rum*` (RUM data)

---

## Dashboard 1: Service Health Overview
**Kibana path:** Dashboards → Create dashboard → "Service Health Overview"
**Tags:** sre-assessment, section-2

### Panel 1a: Request Rate by Service (RED - Rate)
- **Type:** Lens — Bar chart (vertical stacked)
- **Index:** traces-apm*
- **X-axis:** @timestamp (date histogram, auto interval)
- **Y-axis:** Count of transactions
- **Breakdown:** service.name
- **Filter:** transaction.type: "request"

### Panel 1b: Error Rate by Service (RED - Errors)
- **Type:** Lens — Line chart
- **Index:** traces-apm*
- **Y-axis:** Count where transaction.result: "HTTP 5xx" OR event.outcome: "failure"
  divided by total Count → use formula: count(kql='event.outcome: "failure"') / count()
- **Breakdown:** service.name
- **Add threshold line:** at 5% (red dashed)

### Panel 1c: Latency p50/p90/p99 by Service (RED - Duration)
- **Type:** Lens — Table
- **Index:** traces-apm*
- **Rows:** service.name
- **Columns:**
  - Percentile(transaction.duration.us, 50) → label "p50 (ms)" → format: divide by 1000
  - Percentile(transaction.duration.us, 90) → label "p90 (ms)"
  - Percentile(transaction.duration.us, 99) → label "p99 (ms)"

### Panel 1d: Service Dependency Map
- **Type:** Embed the APM Service Map
- **Navigate:** Kibana → APM → Service Map → Copy embed link
- **Alternative:** Use Lens with service.name as source, span.destination.service.resource as target

### Panel 1e: Apdex Score per Service
- **Type:** Lens — Metric (one per service)
- **Formula:**
  (count(kql='transaction.duration.us < 500000') + 0.5 * count(kql='transaction.duration.us >= 500000 AND transaction.duration.us < 2000000')) / count()
- **Color coding:** Green >0.9, Yellow 0.7-0.9, Red <0.7

### Panel 1f: Error Rate Trend with Anomaly
- **Type:** Lens — Line chart with reference line
- **Index:** traces-apm*
- **Y-axis:** Error rate (formula from 1b)
- **Add ML anomaly detection:** If license permits, create ML job on error rate
- **Otherwise:** Add manual threshold reference line at 5%

---

## Dashboard 2: Frontend / RUM Performance
**Kibana path:** Dashboards → Create dashboard → "RUM Performance"

### Panel 2a: Core Web Vitals
- **Type:** Lens — Gauge (4 separate gauges)
- **Index:** traces-apm-rum* or use the built-in User Experience dashboard
- **Metrics:**
  - LCP: transaction.marks.agent.largestContentfulPaint
    - Good: <2500ms (green) | Needs improvement: 2500-4000ms (yellow) | Poor: >4000ms (red)
  - FID: transaction.marks.agent.firstInputDelay (or user_agent.first_input_delay)
    - Good: <100ms | Needs improvement: 100-300ms | Poor: >300ms
  - CLS: transaction.experience.cls
    - Good: <0.1 | Needs improvement: 0.1-0.25 | Poor: >0.25
  - TTFB: transaction.marks.agent.timeToFirstByte
    - Good: <800ms | Needs improvement: 800-1800ms | Poor: >1800ms

### Panel 2b: Page Load Waterfall Breakdown
- **Type:** Lens — Horizontal bar (stacked)
- **Breakdown fields from transaction.marks:**
  - DNS lookup, TCP connection, TLS handshake, TTFB, Content download, DOM processing
- **X-axis:** Duration (ms)

### Panel 2c: Performance by Route
- **Type:** Lens — Table
- **Rows:** transaction.name (page route)
- **Columns:** p50, p90, p99 of transaction.duration.us

### Panel 2d: Geographic User Distribution
- **Type:** Kibana Maps
- **Data source:** traces-apm-rum*
- **Layer:** client.geo.location
- **Metric:** Average latency (color heat)

### Panel 2e: JS Error Tracking
- **Type:** Lens — Table
- **Index:** traces-apm-rum* (filtered: event.outcome: "failure")
- **Columns:** error.message, count, service.name
- **Sort:** count descending

---

## Dashboard 3: Business Transaction Monitoring
**Kibana path:** Dashboards → Create dashboard → "Business Transaction Monitoring"

### Panel 3a: Checkout Funnel
- **Type:** Lens — Multi-series bar chart or TSVB
- **Stages (each is a count of transactions by name):**
  - "browse" → transaction.name contains "/" (homepage)
  - "product-view" → transaction.name contains "/product/"
  - "add-to-cart" → transaction.name contains "POST /cart"
  - "checkout" → transaction.name contains "POST /cart/checkout"
  - "payment" → service.name: "paymentservice"
  - "confirmation" → transaction.name contains "/cart/checkout" response 200

### Panel 3b: Revenue-Correlated Latency (Dual Axis)
- **Type:** Lens — Dual axis chart
- **Left Y:** p95(transaction.duration.us) for checkout transactions
- **Right Y:** Count of successful checkout transactions
- **X-axis:** @timestamp

### Panel 3c: Cart Abandonment Indicator
- **Type:** Lens — Line chart
- **Series 1:** Count of "POST /cart" transactions (cart additions)
- **Series 2:** Count of successful checkouts
- **Gap = abandonment**

### Panel 3d: Custom Business Metrics
- **Type:** Lens — Various panels using metrics-* index
- **Metrics from Section 1 instrumentation:**
  - cart_operations_total (from cartservice)
  - payment_attempts_total by status (from paymentservice)
  - frontend.http_requests_by_route (from frontend)

---

## Dashboard Controls (add to all dashboards)
- **Time picker:** Already built-in
- **Service filter:** Add Kibana Options List control → field: service.name
- **Environment filter:** Add Options List control → field: deployment.environment
- **Host filter (for infra):** Add Options List control → field: host.name

## Export Steps
After creating all dashboards:
1. Run: `bash scripts/export-dashboards.sh`
2. Verify NDJSON files in `dashboards/` directory
3. Commit to Git
