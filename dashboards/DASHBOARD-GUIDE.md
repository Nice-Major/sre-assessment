# =============================================================================
# DASHBOARD CREATION GUIDE
# =============================================================================
# PURPOSE:
#   Step-by-step instructions for creating the 3 required Kibana dashboards.
#   Dashboards are created manually in the Kibana UI (not via code) because
#   Kibana's visualization builder is visual and interactive.
#
# AFTER CREATING DASHBOARDS:
#   Export them as NDJSON files using Kibana's Saved Objects export:
#   Kibana → Stack Management → Saved Objects → Select dashboard → Export
#   Save the NDJSON files in this dashboards/ directory.
# =============================================================================

## Dashboard 1: Service Health Overview

### What it shows:
The RED method (Rate, Errors, Duration) for all microservices — the standard
way to monitor service health at a glance.

### Panels to create:

**Panel 1a: Request Rate by Service (Bar Chart)**
- Index: `traces-apm*`
- Y-axis: Count
- X-axis: Date histogram (auto)
- Series split: `service.name`
- Shows: How many requests each service handles per time bucket

**Panel 1b: Error Rate by Service (Line Chart)**
- Index: `traces-apm*`
- Filter: `event.outcome: failure`
- Y-axis: Count / Total count (percentage)
- Series: `service.name`
- Add threshold line at 5%
- Shows: Percentage of requests that fail per service

**Panel 1c: Latency p50/p90/p99 (Data Table)**
- Index: `traces-apm*`
- Metrics: Percentile of `transaction.duration.us` (50th, 90th, 99th)
- Rows: `service.name`
- Shows: Response time distribution per service

**Panel 1d: Service Dependency Map**
- Type: Embed APM Service Map (Observability → APM → Service Map)
- Or: Link panel to APM Service Map page
- Shows: Which services call which, with throughput on edges

**Panel 1e: Apdex Scores (Metric Gauges)**
- For each key service (frontend, cartservice, paymentservice)
- Formula: (satisfactory + tolerating*0.5) / total
- Thresholds: Green >0.9, Yellow 0.7-0.9, Red <0.7
- Shows: User satisfaction score per service

---

## Dashboard 2: RUM Performance

### What it shows:
Real User Monitoring data — how the application performs from the END USER's
perspective (browser-side metrics).

### Panels to create:

**Panel 2a: Core Web Vitals (4 Gauges)**
- LCP (Largest Contentful Paint): Good <2.5s, Needs improvement <4s, Poor >4s
- FID (First Input Delay): Good <100ms, Needs improvement <300ms, Poor >300ms
- CLS (Cumulative Layout Shift): Good <0.1, Needs improvement <0.25, Poor >0.25
- TTFB (Time to First Byte): Good <800ms, Needs improvement <1800ms, Poor >1800ms
- Index: `rum-*` or APM RUM data streams
- Shows: Google's standardized performance metrics

**Panel 2b: Page Load Waterfall (Horizontal Stacked Bar)**
- Metrics: DNS, TCP, TLS, TTFB, Content Download, DOM Processing
- Index: `rum-*`
- Shows: Where page load time is spent (identify bottlenecks)

**Panel 2c: Performance by Route (Data Table)**
- Rows: `url.path` or `transaction.name`
- Metrics: p50, p90, p99 of page load time
- Shows: Which pages are slowest

**Panel 2d: Geographic Distribution (Map)**
- Type: Kibana Maps
- Field: `client.geo.location`
- Metric: Average page load time (color heat)
- Shows: Where users are and how performance varies by region

**Panel 2e: JavaScript Errors (Data Table)**
- Index: `rum-*`
- Filter: `error.type: *`
- Columns: error.message, count, service.name, url.path
- Sort: count descending
- Shows: Most common browser-side errors

---

## Dashboard 3: Business Transaction Monitoring

### What it shows:
Business-level metrics that map technical data to business outcomes.

### Panels to create:

**Panel 3a: Checkout Funnel (Horizontal Bar)**
- Stages (each is a count of transactions):
  1. Browse (homepage views)
  2. Product View (product page views)
  3. Add to Cart (cart operations)
  4. Checkout Started (checkout page views)
  5. Payment (payment service calls)
  6. Confirmation (email service calls)
- Shows: Where users drop off in the purchase flow

**Panel 3b: Revenue-Correlated Latency (Dual Axis)**
- Left Y-axis: p95 latency of checkoutservice
- Right Y-axis: Count of successful checkouts
- X-axis: Time
- Shows: Whether high latency correlates with fewer completions

**Panel 3c: Cart Abandonment (Area Chart)**
- Series 1: "Add to Cart" count
- Series 2: "Checkout success" count
- Gap between them = cart abandonment
- Shows: How many carts are abandoned before checkout

**Panel 3d: Custom Business Metrics (Metric Panels)**
- `cart_operations_total` — Total cart operations (add/remove/empty)
- `payment_attempts_total` — Payment attempts by status (success/failure)
- `frontend.http_requests_by_route` — Request distribution by page
- Shows: Key business KPIs at a glance

---

## Dashboard Controls (All Dashboards)

Add these filter controls to the top of every dashboard:
1. **Time picker** — Built-in (top-right corner)
2. **Service filter** — Options input control for `service.name`
3. **Environment filter** — Options input control for `service.environment`
4. **Host filter** — Options input control for `host.name`

---

## Exporting Dashboards

After creating dashboards in Kibana:

1. Go to: Stack Management → Saved Objects
2. Select the dashboard
3. Click "Export" → Include related objects → Export
4. Save the `.ndjson` file in this `dashboards/` directory
5. Commit to git

To import on a new cluster:
1. Go to: Stack Management → Saved Objects → Import
2. Upload the `.ndjson` file
3. Select "Overwrite existing" if re-importing
