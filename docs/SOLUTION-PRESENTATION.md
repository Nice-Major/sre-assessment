# SRE Practical Assessment — Solution Presentation

**Project:** Production-grade observability platform for [Google Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo)  
**Stack:** Elastic Stack 8.13.4 + OpenTelemetry + Azure Kubernetes Service + GitHub Actions  
**Audience:** Anyone evaluating or reproducing this implementation

---

## Table of Contents

1. [What This Solves](#what-this-solves)
2. [Architecture Overview](#architecture-overview)
3. [Data Flow: How Every Signal Gets to Kibana](#data-flow)
4. [Step-by-Step Deployment Walkthrough](#deployment-walkthrough)
5. [What to Verify in Kibana (With Screenshots Guide)](#verification-guide)
6. [Alerting Rules Explained](#alerting-rules)
7. [Real User Monitoring (RUM)](#rum)
8. [Known Limitations and How We Handle Them](#known-limitations)
9. [Bug Fixes Applied in This Assessment](#bug-fixes)
10. [Frequently Asked Questions](#faq)

---

## What This Solves

The assessment asks: *Can you build and operate a production-grade observability platform on Kubernetes?*

We demonstrate four monitoring categories across a real 11-service microservices application:

| Category | What We Monitor | How |
|---|---|---|
| **3.1 Compute** | CPU, memory, disk, network per AKS node | OTel Agent `hostmetrics` + Elastic Agent |
| **3.2 Databases** | PostgreSQL connections/cache, Redis memory/evictions | Elastic Agent integrations |
| **3.3 Network** | Denied connections, policy violations, audit log | Calico policies + Filebeat |
| **3.4 Load Balancer** | NGINX request rates, 5xx errors, latency | Elastic Agent NGINX integration |

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│  BROWSER                                                             │
│                                                                      │
│  ┌─────────────────────┐   ┌────────────────────────────────────┐   │
│  │  Online Boutique UI │   │  Elastic APM RUM Agent (optional)  │   │
│  │  http://IP.nip.io   │   │  Sends: page load, Web Vitals,     │   │
│  └──────────┬──────────┘   │  distributed browser spans         │   │
│             │              └──────────────────┬───────────────────┘  │
└─────────────┼────────────────────────────────┼──────────────────────┘
              │ HTTP                            │ HTTP to apm.IP.nip.io
              ▼                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│  NGINX INGRESS CONTROLLER (Azure Load Balancer — public IP)         │
│                                                                     │
│  IP.nip.io           → online-boutique/frontend:80                  │
│  kibana.IP.nip.io    → elastic/kibana-kb-http:5601                  │
│  apm.IP.nip.io       → elastic/apm-server-apm-http:8200            │
└────────┬────────────────────────────────┬────────────────────────────┘
         │                                │
         ▼                                ▼
┌────────────────────────┐   ┌────────────────────────────────────────┐
│  Namespace: elastic    │   │  Namespace: online-boutique            │
│                        │   │                                        │
│  Elasticsearch 8.13.4  │   │  frontend (Go) ──────────────────┐    │
│    └─ stores all data  │   │  cartservice (C#) ──── Redis ─────┤    │
│                        │◄──│  checkoutservice (Go) ────────────┤    │
│  Kibana 8.13.4         │   │  paymentservice (Node.js) ─────────┤   │
│    └─ visualizes data  │   │  currencyservice (Node.js) ────────┤   │
│                        │   │  shippingservice (Go) ─────────────┤   │
│  APM Server 8.13.4     │   │  recommendationservice (Python) ───┤   │
│    └─ receives traces  │   │  emailservice (Python) ────────────┤   │
│      from OTel Gateway │   │  adservice (Java) ─────────────────┤   │
│      + RUM from browser│   │  productcatalogservice (Go) ───────┤   │
│                        │   │  loadgenerator (Python/Locust) ────┘   │
│  Fleet Server 8.13.4   │   │                                        │
│    └─ manages agents   │   │  postgresql (StatefulSet — added       │
│                        │   │    for DB monitoring reqs)             │
└────────────────────────┘   └──────────────────────┬─────────────────┘
                                                     │ OTLP gRPC :4317
                                                     ▼
┌────────────────────────────────────────────────────────────────────┐
│  Namespace: otel-system                                            │
│                                                                    │
│  ┌─────────────────────────────────┐                              │
│  │  OTel Gateway (Deployment ×1)   │                              │
│  │  Receives from ALL agents       │                              │
│  │  Performs TAIL-BASED SAMPLING:  │                              │
│  │    100% error traces            │──→ APM Server (HTTPS :8200)  │
│  │    100% slow traces (>1s)       │                              │
│  │    10% normal traces            │                              │
│  └─────────────────────────────────┘                              │
│                 ▲                                                  │
│  ┌──────────────┴──────────────────┐                              │
│  │  OTel Agent (DaemonSet ×N)      │                              │
│  │  One per AKS node               │                              │
│  │  Receives local pod OTLP        │                              │
│  │  Collects hostmetrics (CPU/mem) │                              │
│  │  Enriches with K8s metadata     │                              │
│  └─────────────────────────────────┘                              │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│  Namespace: monitoring                                             │
│                                                                    │
│  Elastic Agent DaemonSet (standalone)                              │
│    └─ system.cpu / memory / disk / network (per node)             │
│    └─ postgresql.activity / database / bgwriter                   │
│    └─ redis.info / keyspace                                        │
│    └─ nginx.stubstatus                                             │
│    └─ Sends directly to Elasticsearch                              │
│                                                                    │
│  kube-audit Filebeat DaemonSet                                     │
│    └─ Reads /var/log/kubernetes/audit/*.log                        │
│    └─ Filters NetworkPolicy changes                                │
│    └─ Ships to Elasticsearch index: logs-kube-audit-*              │
└────────────────────────────────────────────────────────────────────┘
```

---

## Data Flow: How Every Signal Gets to Kibana

### Distributed Traces (APM → Elasticsearch)

```
1. User visits http://IP.nip.io (Online Boutique store)
2. NGINX routes request → frontend pod (Go)
3. frontend's OTel SDK creates a trace span for the HTTP request
4. frontend calls checkoutservice (gRPC) → creates child spans
5. checkoutservice calls paymentservice, shippingservice → more child spans
6. Each pod sends OTLP spans to:
     OTEL_EXPORTER_OTLP_ENDPOINT = http://otel-gateway...:4317
7. OTel Gateway buffers ALL spans of this trace (waits 10 seconds)
8. Gateway decides: error? → keep 100% | slow? → keep 100% | normal → keep 10%
9. Gateway sends kept spans to APM Server (HTTPS :8200)
10. APM Server indexes into Elasticsearch: traces-apm-default-*
11. Kibana → Observability → APM shows named services + trace waterfall
```

### Infrastructure Metrics (Elastic Agent → Elasticsearch)

```
1. Elastic Agent DaemonSet runs on every AKS node
2. Polls: PostgreSQL, Redis, NGINX stub_status endpoints
3. Collects: system CPU/memory/disk from /proc, /sys
4. Ships to Elasticsearch: metrics-system.*, metrics-postgresql.*, metrics-redis.*
5. Kibana → Infrastructure → Metrics shows per-node dashboards
6. Alerting rules query these metrics and fire when thresholds breached
```

### Host Metrics via OTel (Agent → Gateway → Elasticsearch)

```
1. OTel Agent DaemonSet (on each node) runs hostmetrics scraper
2. Collects CPU%, memory, disk I/O, network bytes from the node
3. Forwards to OTel Gateway → APM Server
4. Appears in Kibana APM as service.name=otel-agent metrics
```

### Kubernetes Audit Logs (Filebeat → Elasticsearch)

```
1. Kubernetes API server writes audit events to /var/log/kubernetes/audit/
2. kube-audit Filebeat reads these files
3. Filters for NetworkPolicy create/update/delete events only
4. Ships to Elasticsearch: logs-kube-audit-*
5. Kibana → Logs → Stream provides searchable audit trail
```

---

## Deployment Walkthrough

### Prerequisites

Before you begin, you need:

1. **An Azure subscription** with at least `Contributor` role
2. **A GitHub account** with a fork of this repository
3. **One GitHub repository secret** configured:
   ```
   Secret name: AZURE_CREDENTIALS
   Secret value: Output of this command:
   
   az ad sp create-for-rbac \
     --name "github-sre-assessment" \
     --role contributor \
     --scopes /subscriptions/<YOUR_SUBSCRIPTION_ID> \
     --sdk-auth
   ```

### Step 1: Deploy Infrastructure (GitHub Actions Workflow 1)

1. In your GitHub repository, go to **Actions** → **"1 - Deploy Infrastructure"**
2. Click **"Run workflow"** with these inputs:
   - Location: `northeurope` (or your preferred region)
   - Node count: `2`
   - Node size: `Standard_D4ads_v6`
3. Wait 8–12 minutes for completion

**What this creates:**
- Azure Resource Group: `sre-assessment-rg`
- AKS Cluster: `sre-assessment-aks` (2 × Standard_D4ads_v6 nodes)
  - Azure CNI networking + Calico network policy enforcement
  - Kubernetes 1.32
- Kubernetes namespaces: `elastic`, `otel-system`, `online-boutique`, `monitoring`
- ECK Operator (manages Elasticsearch/Kibana lifecycle)
- Helm repositories: elastic, open-telemetry, ingress-nginx

**Verify:** ✅ Workflow shows green. No namespace creation errors.

### Step 2: Deploy Observability Stack (Workflow 2)

1. Go to **Actions** → **"2 - Deploy Observability Stack"**
2. Click **"Run workflow"**
3. Wait 10–15 minutes

**What this deploys:**
- Elasticsearch 8.13.4 (single-node, 30GB PVC)
- Kibana 8.13.4 (with Fleet integrations pre-installed)
- APM Server 8.13.4 (OTLP intake + RUM enabled)
- Fleet Server 8.13.4 (for future agent management)
- NGINX Ingress Controller (Azure Load Balancer with public IP)
- OTel Collector Gateway (tail-based sampling: 100% errors, 100% slow, 10% normal)
- OTel Collector Agent (DaemonSet: OTLP receiver + hostmetrics)

**What you'll see in the output:**
```
ACCESS INFORMATION:
  Kibana URL:       http://kibana.20.82.199.114.nip.io
  APM Server URL:   http://apm.20.82.199.114.nip.io
  Elasticsearch:    https://elasticsearch-es-http.elastic.svc:9200 (internal)
  ES Username:      elastic
  ES Password:      <auto-generated>
```

**Verify:**
- Open the Kibana URL in a browser
- Login with `elastic` / `<password from output>`
- ✅ Kibana loads (no "secure connection required" error)

### Step 3: Deploy Application (Workflow 3)

1. Go to **Actions** → **"3 - Deploy Application"**
2. Click **"Run workflow"**
3. Wait 8–10 minutes

**What this deploys:**
- Google Online Boutique v0.10.5 (11 microservices)
- PostgreSQL StatefulSet (for database monitoring)
- OTel instrumentation patches for **all 10 services**:
  - frontend, cartservice, paymentservice, checkoutservice
  - currencyservice, shippingservice, recommendationservice
  - emailservice, adservice, productcatalogservice
- Kubernetes NetworkPolicies (default-deny + allowlisted paths)
- Elastic Agent DaemonSet (system/postgres/redis/nginx metrics)
- kube-audit Filebeat DaemonSet (K8s audit log collection)
- 11 Kibana alerting rules (compute + database + network + NGINX)

**Verify:**
- `http://IP.nip.io` → Shows Online Boutique store
- Browse the store for 1-2 minutes
- Open Kibana → Observability → APM → Services
- ✅ Should see: `frontend`, `checkoutservice`, `paymentservice`, `cartservice`, `currencyservice`, `shippingservice`

---

## Verification Guide

### Step A: Verify Traces Are Flowing

1. Open Kibana → **Observability** → **APM** → **Services**
2. You should see 10 services with names matching the microservices
3. Click on `frontend` → **Transactions** → click any transaction
4. ✅ **Service map** shows the call chain: `frontend → checkoutservice → paymentservice`
5. ✅ **Trace waterfall** shows spans from multiple services under ONE trace ID

**Example trace to trigger:**
```
1. Open http://IP.nip.io
2. Click any product
3. Click "Add to Cart"
4. Click the cart icon → "Place Order"
5. Fill in checkout form → "Place Order"
```
This creates a trace with ~10 spans across 6 services.

**What to look for in Kibana APM:**
```
Transaction: /cart/checkout
  ├─ frontend: POST /cart/checkout            150ms
  │   ├─ checkoutservice: PlaceOrder          130ms
  │   │   ├─ cartservice: GetCart              10ms
  │   │   ├─ productcatalogservice: GetProduct  5ms
  │   │   ├─ currencyservice: Convert          8ms
  │   │   ├─ shippingservice: GetQuote         12ms
  │   │   ├─ paymentservice: Charge            45ms
  │   │   └─ emailservice: SendConfirmation    20ms
  │   └─ (span ends)
```

### Step B: Verify Infrastructure Metrics

1. Kibana → **Infrastructure** → **Metrics** → **Hosts**
2. ✅ Should show 2 AKS nodes with CPU, memory, network panels

Or via APM data: Kibana → **Observability** → **Infrastructure**

**PostgreSQL metrics:**
- Kibana → **Discover** → search index pattern `metrics-postgresql-*`
- ✅ Should see documents with `postgresql.activity.connections`

**Redis metrics:**
- Kibana → **Discover** → search `metrics-redis-*`
- ✅ Should see `redis.info.memory.used.value`

### Step C: Verify Alerting Rules

1. Kibana → **Stack Management** → **Rules** (or **Observability** → **Alerts**)
2. ✅ Should see 11 rules created, all in "OK" state (meaning thresholds not currently breached)
3. Rules are: High CPU, Disk Critical, Memory Pressure, PostgreSQL Connections, PostgreSQL Cache, Redis Memory, Redis Eviction, External Egress, NGINX 5xx, NGINX 502/503, SSL Certificate

**To test an alert fires:**
```bash
# SSH into a pod and stress the CPU (test only)
kubectl exec -n online-boutique deploy/frontend -- sh -c "
  for i in \$(seq 1 4); do while true; do :; done & done
  sleep 360
  kill %1 %2 %3 %4
"
# Watch for "High CPU Usage" alert in Kibana after ~5 minutes
```

### Step D: Verify Network Policies Are Enforced

1. Kibana → **Discover** → search `logs-kube-audit-*`
2. ✅ Should see NetworkPolicy CRUD events (your policy applications in Step 3)

**Test a policy is enforced (connection is blocked):**
```bash
# Create a pod and try to call a service it's not allowed to reach
kubectl run test-pod --image=curlimages/curl -n online-boutique -it --rm -- \
  curl -s --max-time 3 http://elasticsearch-es-http.elastic.svc:9200
# Should time out (blocked by default-deny + no egress to elastic namespace)
```

### Step E: Verify RUM (Optional — Requires Manual Steps)

RUM requires injecting a JavaScript agent into the frontend HTML. Since the Online Boutique runs pre-built Docker images, this requires a custom image build. The configuration is in `instrumentation/rum/rum-init.html`.

**To manually verify RUM is working via browser DevTools:**
```javascript
// Open browser developer console on http://IP.nip.io
// Paste this to manually initialize the RUM agent:
var s = document.createElement('script');
s.src = 'https://unpkg.com/@elastic/apm-rum@5.16.0/dist/bundles/elastic-apm-rum.umd.min.js';
s.onload = function() {
  elasticApm.init({
    serviceName: 'frontend-rum',
    serverUrl: 'http://apm.IP.nip.io',  // Replace IP with actual IP
    serviceVersion: '1.0.0',
    environment: 'assessment'
  });
  console.log('✅ RUM agent initialized');
};
document.head.appendChild(s);
```

Then navigate around the store. Check Kibana → **Observability** → **User Experience** for page load data.

**Production RUM Implementation Steps (manual):**
```bash
# 1. Clone the microservices-demo repository
git clone https://github.com/GoogleCloudPlatform/microservices-demo.git
cd microservices-demo

# 2. Edit the frontend HTML template
# File: src/frontend/templates/footer.html
# Add before </body>:
cat instrumentation/rum/rum-init.html >> src/frontend/templates/footer.html

# 3. Update the APM Server URL in rum-init.html with your actual IP
sed -i "s/INGRESS_IP_PLACEHOLDER/YOUR_IP/g" src/frontend/templates/footer.html

# 4. Build and push the custom image
REGISTRY=<your-registry>
docker build -t $REGISTRY/frontend-rum:v0.10.5 ./src/frontend
docker push $REGISTRY/frontend-rum:v0.10.5

# 5. Update the Deployment to use the custom image
kubectl set image deployment/frontend server=$REGISTRY/frontend-rum:v0.10.5 \
  -n online-boutique
```

---

## Alerting Rules Explained

All 11 rules are created by `kubernetes/alerting/create-alerting-rules.sh` and live in Kibana → Stack Management → Rules.

### Section 3.1 — Compute

| Rule | Condition | Why This Threshold |
|---|---|---|
| **High CPU Usage** | `system.cpu.system.pct > 85%` for 5 min | 85% sustained = system is saturated; brief spikes are normal |
| **Disk Space Critical** | `system.filesystem.used.pct > 90%` | <10% free = imminent full disk; Elasticsearch stops writing at 95% |
| **Memory Pressure** | `system.memory.actual.free < 500MB` | <500MB = apps start OOM-killing; Elasticsearch JVM needs headroom |

### Section 3.2 — Databases

| Rule | Condition | Why This Threshold |
|---|---|---|
| **PostgreSQL Connections** | `postgresql.activity.connections > 80` | Alert at 80% of `max_connections=100`; 100% = new connections rejected |
| **PostgreSQL Cache Hit Ratio** | High `blks_read` count in 5 min | Excessive disk reads = cache too small or data scanning — needs investigation |
| **Redis Memory** | `redis.info.memory.used.value > 200MB` | Container limit ≈ 256MB; >200MB means approaching eviction threshold |
| **Redis Eviction Rate** | `redis.info.stats.evicted_keys > 100 in 5 min` | Key eviction = cache pressure; cart data loss if evicted aggressively |

### Section 3.3 — Network

| Rule | Condition | Why Use Logs |
|---|---|---|
| **Unexpected External Egress** | Any `event.action=deny` in flow logs | Every denied connection is logged by Calico; non-zero denied egress = policy violation or attack probe |

### Section 3.4 — Load Balancer

| Rule | Condition | Why Use Logs |
|---|---|---|
| **NGINX 5xx Rate** | `>5 responses with status≥500` in 2 min | Backend failures surfaced at NGINX; logs count actual 5xx entries |
| **NGINX 502/503** | `>3 responses with status 502 or 503` in 2 min | 502/503 specifically = backend offline or crashing |
| **SSL Certificate Expiry** | Certificate `not_valid_after < now+14d` | 14-day warning allows time to renew before expiry causes outages |

---

## Real User Monitoring (RUM)

### What RUM Captures

The Elastic APM RUM Agent (JavaScript, loaded in the browser) automatically captures:

| Signal | Description | Kibana Location |
|---|---|---|
| **LCP** | Largest Contentful Paint | User Experience → Web Vitals |
| **FID** | First Input Delay (interaction responsiveness) | User Experience → Web Vitals |
| **CLS** | Cumulative Layout Shift (visual stability) | User Experience → Web Vitals |
| **TTFB** | Time to First Byte | User Experience → Page Load |
| **Backend Correlation** | Browser span linked to server-side trace | APM → Traces (shows frontend+backend together) |

### Architecture

```
Browser
  ├─ Loads page from http://IP.nip.io
  ├─ RUM JS initializes → watches page load metrics
  ├─ User clicks "Add to Cart"
  │    └─ RUM creates transaction "user-interaction"
  │    └─ Browser sends fetch to /cart (with traceparent header injected by RUM)
  │    └─ This links the browser span to the backend trace!
  └─ RUM periodically batches and sends to:
       http://apm.IP.nip.io/intake/v2/rum/events
       (NGINX → APM Server)
```

### Why It Requires a Custom Docker Image

The Online Boutique frontend is a pre-compiled Go binary serving HTML templates. The RUM script must be embedded in the HTML templates at BUILD TIME. There are three paths to RUM:

1. **Custom Docker image** (recommended): Fork the repo, add the snippet to `src/frontend/templates/footer.html`, rebuild.
2. **NGINX sub_filter** (attempted, rejected): NGINX's `sub_filter` directive can inject HTML into responses. We tried this via `configuration-snippet` annotation on the Ingress. **It failed** because NGINX Ingress 4.15+ validates snippets with an admission webhook that blocks `sub_filter` as a known code-injection vector.
3. **Browser DevTools** (testing only): Manually paste the RUM init code into the console for ad-hoc testing without any changes.

---

## Known Limitations and How We Handle Them

### 1. Calico Flow Logs on Managed AKS

**What the design intended:** Calico generates per-connection flow logs → Filebeat reads them → Elasticsearch shows which connections were allowed/denied.

**Reality on AKS:** Azure manages Calico internally on AKS. The Calico Felix process runs but does NOT write flow logs to `/var/log/calico/` on managed nodes. The `FelixConfiguration` CRD is not available on managed AKS.

**How we handle it:**
- The `calico-flow-logs.yaml` DaemonSet deploys and runs (0 errors, just 0 files harvested)
- We use **Kubernetes audit logs** instead (always available on AKS, written to `/var/log/kubernetes/audit/`)
- The `kube-audit-filebeat.yaml` captures all NetworkPolicy CRUD events
- The alerting Rule 8 (Unexpected External Egress) watches audit logs for policy changes as a proxy for network anomalies

### 2. RUM Not Auto-Injected

See [Real User Monitoring](#rum) section above. The APM Server is configured and ready to receive RUM data — the only missing piece is the frontend image with the script embedded.

### 3. Single-Node Elasticsearch

For the assessment, we run Elasticsearch with `count: 1`. In production:
- Minimum 3 nodes for high availability
- Separate data/master/ingest node roles
- Index lifecycle management (ILM) for data retention

### 4. No TLS on Ingress Routes

Connections to Kibana, APM Server, and the Online Boutique are plain HTTP. In production, use cert-manager to provision Let's Encrypt certificates and configure TLS termination at the Ingress.

---

## Bug Fixes Applied in This Assessment

The following issues were found during implementation and fixed:

### BUG-001: Duplicate `receivers:` Key in OTel Agent Config
**File:** `kubernetes/otel-collector/agent-values.yaml`  
**Problem:** The YAML had two `receivers:` keys under `config:`. YAML parsers treat duplicate keys as undefined behavior (most take the last, discarding the first). The first key contained null-outs for default receivers; the second had the actual `otlp` and `hostmetrics` definitions. The null-outs were silently dropped.  
**Impact:** Helm chart default receivers (jaeger, prometheus, zipkin) could be merged back in, causing "no endpoint configured" startup errors.  
**Fix:** Merged both blocks into one `receivers:` key.

### BUG-002: OTel Agent Missing Metrics and Logs Pipelines
**File:** `kubernetes/otel-collector/agent-values.yaml`  
**Problem:** The `service.pipelines` section only defined a `traces:` pipeline. The `hostmetrics` receiver was configured but never wired to any pipeline.  
**Impact:** Zero host metrics (CPU/memory/disk/network) flowing through the agent. All Section 3.1 alerting rules had no data.  
**Fix:** Added `metrics:` pipeline with `[otlp, hostmetrics]` receivers and `logs:` pipeline.

### BUG-003: Alerting Script Truncated — Rule 11 Incomplete
**File:** `kubernetes/alerting/create-alerting-rules.sh`  
**Problem:** The file ended at line 299 mid-JSON inside an unclosed single-quoted string. Bash waits for the closing `'` — in non-interactive mode, the script hangs indefinitely until the GitHub Actions job times out.  
**Impact:** GitHub Actions job times out; all 11 alerting rules may not be created.  
**Fix:** Completed Rule 11 with correct JSON body and added a summary footer.

### BUG-004: Wrong Metrics in Alerting Rules 5, 6, and 9
**File:** `kubernetes/alerting/create-alerting-rules.sh`

| Rule | Wrong Metric | Problem | Fixed To |
|---|---|---|---|
| Rule 5: PG Cache Hit | `postgresql.database.stats.blks_hit` compared to `0.95` | `blks_hit` is millions of block read counts, not a ratio. Will always be > 0.95. | Log-count alert on `blks_read > 0` documents |
| Rule 6: Redis Memory | `redis.info.memory.used.peak` compared to `0.85` | `peak` is bytes (e.g., 52MB). Alert fires immediately since any value > 0.85 bytes. | Uses `redis.info.memory.used.value > 209715200` (200MB in bytes) |
| Rule 9: NGINX 5xx | `nginx.stubstatus.requests` compared to `0.05` | `stubstatus.requests` is a total request count (thousands), not a ratio. Fires immediately. | Log-count alert on NGINX access log entries with `status >= 500` |

### BUG-005: Duplicate `config:` Key in NGINX Values
**File:** `kubernetes/ingress/nginx-values.yaml`  
**Problem:** The `controller.config:` block appeared twice. The second block (with `log-format-upstream`) overwrote the first (with `allow-snippet-annotations`).  
**Impact:** `allow-snippet-annotations: "true"` was silently dropped from the NGINX ConfigMap, so any Ingress with `configuration-snippet` annotations was rejected.  
**Fix:** Merged into a single `config:` block with all values.

### BUG-006: NGINX enable-opentelemetry Without Backend
**File:** `kubernetes/ingress/nginx-values.yaml`  
**Problem:** `enable-opentelemetry: "true"` was set in NGINX config. This loads the NGINX OTel module which tries to export spans to an OTLP endpoint — but no endpoint was configured.  
**Impact:** NGINX workers continuously logged `OTLP TRACE GRPC Exporter Export() failed` errors. Potential performance impact from failed export retries.  
**Fix:** Removed `enable-opentelemetry: "true"`. NGINX request data is captured through application OTel instead.

### BUG-007: Only 3 of 10 Services Had Instrumentation Patches
**Files missing:** `instrumentation/checkoutservice/k8s-patch.yaml` and 6 others  
**Problem:** The GitHub Actions workflow `3-deploy-application.yml` loops over `instrumentation/*/k8s-patch.yaml` to apply OTel env vars. Only `frontend`, `cartservice`, and `paymentservice` had patch files. No patch = no `ENABLE_TRACING=1` = no telemetry from that service.  
**Impact:** `checkoutservice`, `currencyservice`, `shippingservice`, `recommendationservice`, `emailservice`, `adservice`, `productcatalogservice` sent no traces. The service map in Kibana was incomplete. End-to-end traces had gaps.  
**Fix:** Created patch files for all 7 missing services.

### BUG-008: No Elastic Agent Running Infrastructure Metrics
**Files:** `kubernetes/monitoring/elastic-agent-config.yaml` (ConfigMap only), no DaemonSet  
**Problem:** The workflow applied a ConfigMap named `elastic-agent-monitoring-config` which stored the monitoring policies — but no actual Elastic Agent process existed to READ this ConfigMap.  
**Impact:** Zero PostgreSQL, Redis, NGINX, or system metrics in Elasticsearch. All Section 3.2 alerting rules had no data.  
**Fix:** Created `kubernetes/monitoring/elastic-agent-daemonset.yaml` — an actual Elastic Agent DaemonSet in standalone mode that mounts the config and runs the integrations.

### BUG-009: Kibana publicBaseUrl Never Updated After NGINX Gets IP
**File:** `kubernetes/elastic-stack/kibana.yaml` + `.github/workflows/2-deploy-observability.yml`  
**Problem:** `kibana.yaml` contains `server.publicBaseUrl: "http://kibana.INGRESS_IP_PLACEHOLDER.nip.io"`. The ECK resource is applied in workflow step "Deploy Kibana" — before NGINX is deployed and before the cluster has a public IP. The placeholder was never replaced.  
**Impact:** Kibana generates incorrect redirect URLs. Fleet enrollment links and APM deep-links use the placeholder hostname.  
**Fix:** Added a `kubectl patch kibana kibana -n elastic` command in the "Create Ingress Routes" step, after the IP is known.

### BUG-010: ingress-nginx Namespace Missing from namespaces.yaml
**File:** `kubernetes/base/namespaces.yaml`  
**Problem:** The `ingress-nginx` namespace (created by Helm) had no `kubernetes.io/metadata.name: ingress-nginx` label. Kubernetes NetworkPolicies use `namespaceSelector.matchLabels` to target namespaces. The policy `allow-ingress-to-frontend` selector matched on this label — but since Helm creates the namespace without the label, the selector never matched, and the policy silently blocked NGINX from reaching the frontend.  
**Fix:** Added `ingress-nginx` namespace definition to namespaces.yaml with the correct label. `kubectl apply` will either create it (if Helm hasn't run yet) or update just the labels (if Helm has already created it).

---

## Frequently Asked Questions

**Q: Why does the deployment use three separate GitHub Actions workflows instead of one?**  
A: Each layer takes significant time and has clear completion prerequisites. Infrastructure (AKS creation: 8min) → Observability (Elastic Stack startup: 10min) → Application. Separating them means failures are isolated, each can be re-run independently, and the progression is auditable.

**Q: Why tail-based sampling instead of head-based?**  
A: Head-based sampling decides at trace START whether to keep it. But you don't know if a downstream service will throw an error until the trace ENDS. Tail-based sampling (on the Gateway) waits for the complete trace, then decides: "this had an error = keep it." This guarantees 100% capture of error traces regardless of sampling rate.

**Q: Why is the OTel Agent pointing to the Gateway instead of using hostPort?**  
A: The OTel Agent DaemonSet uses `hostPort: 4317` for low-latency pod-to-agent communication on the same node. However, the Online Boutique services use `OTEL_EXPORTER_OTLP_ENDPOINT` with the Gateway's ClusterIP DNS name. This works because the Gateway is a ClusterIP service reachable by all pods. The Agent DaemonSet doesn't have a ClusterIP service — only a hostPort. Using the Gateway directly slightly bypasses the per-node Agent enrichment but is reliable and doesn't require pod-to-node IP routing.

**Q: Why is there a separate PostgreSQL StatefulSet? The Online Boutique uses Redis for cart, not SQL.**  
A: The assessment Section 3.2 requires relational database monitoring. The original Online Boutique doesn't include a SQL database. We add PostgreSQL explicitly as a "monitoring workload" — it runs alongside the app and serves as the target for DB alerting rules. It's not connected to any application logic.

**Q: The loadgenerator is constantly hitting the frontend — won't this create too many traces?**  
A: The OTel Gateway's tail-based sampling keeps only 10% of healthy traces. With the loadgenerator at default rate (~10 requests/second), we generate ~6 traces/second, keep ~0.6/second for baseline, plus any errors/slow requests. This is manageable for a single-node Elasticsearch on 30GB.

**Q: How do I get the Elasticsearch password after deployment?**  
A: ```bash
kubectl get secret elasticsearch-es-elastic-user -n elastic \
  -o jsonpath='{.data.elastic}' | base64 -d
```

**Q: How do I destroy everything and stop Azure costs?**  
A: Run the **"🗑️ Destroy All Resources"** GitHub Actions workflow. Type `destroy` in the confirmation field. This deletes the entire Azure Resource Group (AKS cluster, load balancer, disks, IP addresses). All data in Elasticsearch is permanently lost.
