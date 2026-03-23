# SRE Practical Assessment -- Complete Implementation

Production-grade observability platform for Google's [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) (11 polyglot microservices) using **Elastic Stack 8.13.4** + **OpenTelemetry** on **Azure Kubernetes Service (AKS)**, deployed end-to-end via **GitHub Actions**.

> **For the full architecture narrative, bug-fix log, and Kibana walkthrough see [docs/SOLUTION-PRESENTATION.md](docs/SOLUTION-PRESENTATION.md).**
> **For architectural decisions and rationale see [docs/DECISIONS.md](docs/DECISIONS.md).**

---

## Table of Contents

1. [Architecture](#architecture)
2. [Repository Structure](#repository-structure)
3. [Prerequisites](#prerequisites)
4. [Deployment (GitHub Actions -- 3 Steps)](#deployment)
5. [Validation: Verify Every Signal in Kibana](#validation)
   - [Section 3.1 -- Compute Metrics](#section-31--compute-metrics)
   - [Section 3.2 -- Database Metrics](#section-32--database-metrics)
   - [Section 3.3 -- Network Monitoring](#section-33--network-monitoring)
   - [Section 3.4 -- Load Balancer Monitoring](#section-34--load-balancer-monitoring)
   - [Distributed Traces (APM)](#distributed-traces-apm)
   - [Alerting Rules](#alerting-rules)
   - [RUM -- Real User Monitoring](#rum--real-user-monitoring)
6. [Telemetry Signal Summary](#telemetry-signal-summary)
7. [Alerting Rules Reference](#alerting-rules-reference)
8. [Bugs Fixed in This Implementation](#bugs-fixed-in-this-implementation)
9. [Tear Down](#tear-down)

---

## Architecture

```
+----------------------------------------------------------------------+
| BROWSER                                                              |
|   Online Boutique UI   http://IP.nip.io                             |
|   APM RUM Agent (opt)  apm.IP.nip.io  (page load + Web Vitals)     |
+----------------+---------------------------+-------------------------+
                 | HTTP                      | RUM events
                 v                           v
+----------------------------------------------------------------------+
| AZURE LOAD BALANCER  (public IP via NGINX Ingress Controller)        |
|   IP.nip.io            ->  online-boutique/frontend:80              |
|   kibana.IP.nip.io     ->  elastic/kibana-kb-http:5601             |
|   apm.IP.nip.io        ->  elastic/apm-server-apm-http:8200        |
+------------------------------+---------------------------------------+
                               |
          +--------------------+-------------------+
          v                    v                   v
+-----------------+   +-----------------+   +------------------------+
| online-boutique |   | otel-system     |   | elastic                |
|                 |   |                 |   |                        |
| frontend  (Go)  |   | OTel Agent      |   | Elasticsearch 8.13.4   |
| cartservice(C#) |   | DaemonSet       |   |  (all traces/metrics/  |
| checkout  (Go)  |   |  - OTLP recv    |   |   logs stored here)    |
| payment (Node)  +-->|  - hostmetrics  |   |                        |
| currency (Node) |   |  - k8sattribs   |   | Kibana 8.13.4          |
| shipping  (Go)  |   |  -> Gateway     |   |  (dashboards + APM UI  |
| recommend (Py)  |   |                 |   |   + alerting)          |
| email     (Py)  |   | OTel Gateway    |   |                        |
| adservice (Java)|   | Deployment      |   | APM Server 8.13.4      |
| productcatalog  |   |  - tail-sampling+-->|  (OTLP + RUM intake)   |
|  (Go)           |   |  - 100% errors  |   |                        |
| loadgenerator   |   |  - 100% slow>1s |   | Fleet Server 8.13.4    |
|                 |   |  - 10% healthy  |   |  (config delivery)     |
+-----------------+   +-----------------+   +------------------------+
                                                        ^
+------------------------------------------------------+|
| monitoring (namespace)                               ||
|   Elastic Agent DaemonSet                           ||
|     - system metrics (CPU/mem/disk/net)             ||
|     - PostgreSQL metrics (metrics-postgresql.*)     ||
|     - Redis metrics     (metrics-redis.*)           ||
|     - NGINX stub_status (metrics-nginx.*)           ||
+------------------------------------------------------+
```

**Telemetry flows:**
- App OTLP spans/metrics -> OTel Agent -> OTel Gateway -> APM Server -> Elasticsearch
- Node-level host metrics -> OTel Agent hostmetrics -> OTel Gateway -> APM Server -> Elasticsearch
- DB/NGINX integration metrics -> Elastic Agent DaemonSet -> Elasticsearch direct
- kube-audit logs -> Filebeat DaemonSet -> Elasticsearch (Calico flow logs: not available on AKS -- kube-audit used as substitute)

---

## Repository Structure

```
.github/workflows/
  1-provision-aks.yml          # Create AKS cluster (idempotent, ~8 min)
  2-deploy-observability.yml   # ECK + OTel Collector + NGINX Ingress
  3-deploy-application.yml     # Online Boutique + tracing patches + Elastic Agent

docs/
  DECISIONS.md                 # Architectural decisions and rationale
  SOLUTION-PRESENTATION.md     # Full narrative, architecture, and Kibana guide (NEW)

dashboards/
  service-health.ndjson        # APM service health overview
  business-transactions.ndjson # Business KPI dashboard
  rum-performance.ndjson       # RUM / Web Vitals dashboard
  DASHBOARD-GUIDE.md           # Import steps and panel descriptions

infrastructure/
  alerting-rules/
    create-alerting-rules.sh   # 11 alerting rules via Kibana API
  elastic-agent-policies/
    system-policy.yaml         # Fleet system integration policy
  network-policies/
    network-policies.yaml      # 9 Kubernetes NetworkPolicies
    calico-flow-logs.yaml      # Calico config (AKS limitation: not applied)
    kube-audit-filebeat.yaml   # kube-audit Filebeat DaemonSet
  nginx-integration/
    nginx-config.yaml          # Elastic Agent NGINX integration config
  postgres-integration/
    postgresql-config.yaml     # Elastic Agent PostgreSQL integration config
  redis-integration/
    redis-config.yaml          # Elastic Agent Redis integration config

instrumentation/
  cartservice/
    k8s-patch.yaml             # OTLP env vars + ENABLE_TRACING for C# service
    OtelConfig.cs              # OpenTelemetry SDK setup for ASP.NET Core
  frontend/
    k8s-patch.yaml             # OTLP env vars for Go frontend
    otel_init.go               # OTel SDK init (TracerProvider + propagation)
    README.md
  paymentservice/
    k8s-patch.yaml             # OTLP env vars + ENABLE_TRACING for Node service
    tracing.js                 # OTel Node.js SDK setup
    custom-spans.js            # Business-relevant span attributes
  checkoutservice/
    k8s-patch.yaml             # OTLP env vars + ENABLE_TRACING (NEW)
  currencyservice/
    k8s-patch.yaml             # OTLP env vars + ENABLE_TRACING (NEW)
  shippingservice/
    k8s-patch.yaml             # OTLP env vars + ENABLE_TRACING (NEW)
  recommendationservice/
    k8s-patch.yaml             # OTLP env vars + ENABLE_TRACING (NEW)
  emailservice/
    k8s-patch.yaml             # OTLP env vars + ENABLE_TRACING (NEW)
  adservice/
    k8s-patch.yaml             # OTEL_ Java agent env vars (NEW)
  productcatalogservice/
    k8s-patch.yaml             # OTLP env vars + ENABLE_TRACING (NEW)

kubernetes/
  cluster-setup.sh
  elastic-stack/
    elasticsearch.yaml         # Single-node ES, 30 GB PVC, TLS disabled
    kibana.yaml                # Kibana, TLS disabled, nip.io publicBaseUrl
    apm-server.yaml            # APM Server with OTLP + RUM enabled
    fleet-server.yaml
    deploy-elastic-stack.sh
  nginx-ingress/
    frontend-ingress.yaml      # Ingress for Online Boutique
    kibana-ingress.yaml        # Ingress for Kibana + APM Server
    deploy-nginx-ingress.sh
  online-boutique/
    deploy-online-boutique.sh
    postgresql.yaml
  monitoring/
    elastic-agent-daemonset.yaml  # Elastic Agent DaemonSet (NEW -- replaces missing ConfigMap)

otel-collector/
  values-agent.yaml            # OTel Agent DaemonSet Helm values (fixed)
  values-gateway.yaml          # OTel Gateway Deployment Helm values
  sampling-policy.yaml         # Tail-based sampling config
  deploy-otel-collector.sh

rum/
  rum-init.html                # APM RUM JS snippet (inject into frontend)
  README.md                    # Manual RUM deployment steps

scripts/
  deploy-all.sh
  provision-aks.sh
  generate-traffic.sh
  export-dashboards.sh
```

---

## Prerequisites

| Item | Value |
|------|-------|
| Azure subscription | Required (Contributor on resource group) |
| GitHub repository secrets | `AZURE_CREDENTIALS`, `AZURE_SUBSCRIPTION_ID` |
| Local tools (optional) | `kubectl`, `helm`, `az` CLI |

**Required GitHub secrets** (set under *Settings > Secrets and variables > Actions*):

```
AZURE_CREDENTIALS          # JSON output of: az ad sp create-for-rbac ...
AZURE_SUBSCRIPTION_ID      # az account show --query id -o tsv
```

---

## Deployment

Run these three GitHub Actions workflows **in order**:

| Step | Workflow | What it does | Time |
|------|----------|-------------|------|
| 1 | **Provision AKS** | Creates `sre-assessment-rg`, AKS 1.32, 2x Standard_D4ads_v6, Azure CNI + Calico | ~8 min |
| 2 | **Deploy Observability** | ECK 8.13.4 (ES + Kibana + APM + Fleet), OTel Collector (Agent + Gateway), NGINX Ingress, Network Policies, kube-audit Filebeat | ~12 min |
| 3 | **Deploy Application** | Online Boutique, PostgreSQL, Redis, Elastic Agent DaemonSet, OTLP tracing patches for all 10 services, alerting rules | ~10 min |

After Workflow 3 completes, the outputs section will print the live URLs.

---

## Validation

> All `kubectl` commands assume your kubeconfig is pointed at `sre-assessment-aks`.
> Replace `<ES_PASSWORD>` with `Z66eloY57z2g677CWVdOxE61` (or retrieve fresh: `kubectl get secret elasticsearch-es-elastic-user -n elastic -o go-template='{{.data.elastic | base64decode}}'`).

### Section 3.1 -- Compute Metrics

**Goal:** Node-level CPU, memory, disk, and network metrics from every AKS node flow into Elasticsearch via the OTel Agent DaemonSet (hostmetrics receiver).

**1. Confirm OTel Agent pods are Running on every node:**
```bash
kubectl get pods -n otel-system -l app=opentelemetry-collector -o wide
# Expected: one pod per node, all STATUS=Running
```

**2. Check that hostmetrics are being collected (from the Agent pod log):**
```bash
kubectl logs -n otel-system -l app=opentelemetry-collector --prefix \
  | grep -i "host\|metric\|cpu" | head -20
```

**3. Count metrics documents in Elasticsearch:**
```bash
curl -sk -u elastic:<ES_PASSWORD> \
  https://localhost:9200/metrics-*/_count \
  --header "Content-Type: application/json" \
  --data '{"query":{"match":{"data_stream.dataset":"hostmetrics"}}}' \
  | python3 -m json.tool
# Expect: "count" > 0, growing every 30 s
```
*(Port-forward ES: `kubectl port-forward svc/elasticsearch-es-http 9200:9200 -n elastic`)*

**4. Kibana -- Infrastructure view:**
- Open `http://kibana.<IP>.nip.io`
- **Observability > Infrastructure > Hosts** -- all AKS nodes appear with CPU / Memory / Network graphs
- Alternatively: **Discover > index pattern `metrics-*`** -- filter `system.cpu.total.pct exists`

---

### Section 3.2 -- Database Metrics

**Goal:** PostgreSQL and Redis integration metrics, scraped by the Elastic Agent DaemonSet, flow into `metrics-postgresql.*` and `metrics-redis.*` indices.

**1. Confirm Elastic Agent DaemonSet is Running:**
```bash
kubectl get pods -n monitoring -l app=elastic-agent
# Expected: one pod per node, STATUS=Running
```

**2. Check Elastic Agent logs for PostgreSQL/Redis collection:**
```bash
kubectl logs -n monitoring -l app=elastic-agent --prefix \
  | grep -iE "postgresql|redis|harvested|events" | tail -30
```

**3. Count PostgreSQL metric documents:**
```bash
curl -sk -u elastic:<ES_PASSWORD> \
  https://localhost:9200/metrics-postgresql.*/_count \
  | python3 -m json.tool
# Expect: "count" > 0
```

**4. Count Redis metric documents:**
```bash
curl -sk -u elastic:<ES_PASSWORD> \
  https://localhost:9200/metrics-redis.*/_count \
  | python3 -m json.tool
# Expect: "count" > 0
```

**5. Kibana -- Discover:**
- Index pattern `metrics-postgresql.*` -- fields like `postgresql.bgwriter.*`, `postgresql.database.*`
- Index pattern `metrics-redis.*` -- fields like `redis.info.memory.used.value`, `redis.info.clients.connected`

---

### Section 3.3 -- Network Monitoring

**Goal:** Kubernetes NetworkPolicies enforce microsegmentation; kube-audit logs (proxy for Calico flow logs, which are unavailable on AKS managed CNI) are indexed in Elasticsearch.

**1. Confirm NetworkPolicies are applied:**
```bash
kubectl get networkpolicies -n online-boutique
# Expected: 9 policies listed (default-deny, allow-frontend-*, allow-*-to-*, etc.)

kubectl get networkpolicies -n elastic
kubectl get networkpolicies -n otel-system
```

**2. Test a blocked connection (policy enforcement):**
```bash
# This should FAIL -- loadgenerator cannot reach cartservice directly
kubectl exec -n online-boutique deploy/loadgenerator -- \
  wget -q --spider --timeout=3 http://cartservice:7070 2>&1
# Expected: "wget: bad address" or timeout (connection blocked by NetworkPolicy)

# This should SUCCEED -- frontend can reach cartservice
kubectl exec -n online-boutique deploy/frontend -- \
  wget -q --spider --timeout=3 http://cartservice:7070 2>&1
# Expected: no output or "200 OK"
```

**3. Check Filebeat kube-audit DaemonSet:**
```bash
kubectl get pods -n kube-system -l app=kube-audit-filebeat
# Expected: pods Running on each node
```

**4. Verify kube-audit logs in Elasticsearch:**
```bash
curl -sk -u elastic:<ES_PASSWORD> \
  https://localhost:9200/.ds-filebeat-*/_count \
  --header "Content-Type: application/json" \
  --data '{"query":{"match":{"kubernetes.audit.verb":"create"}}}' \
  | python3 -m json.tool
# Expect: "count" > 0
```

**5. Kibana -- Discover:**
- Index pattern `filebeat-*` -- filter `kubernetes.audit.objectRef.resource : pods` to see pod-creation audit events

---

### Section 3.4 -- Load Balancer Monitoring

**Goal:** NGINX Ingress Controller emits structured JSON access logs and stub_status metrics; both are ingested by the Elastic Agent DaemonSet.

**1. Confirm NGINX stub_status endpoint is reachable:**
```bash
kubectl port-forward -n ingress-nginx \
  $(kubectl get pod -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -o name | head -1) \
  10254:10254 &

curl -s http://localhost:10254/stub_status
# Expected output:
# Active connections: 3
# server accepts handled requests
#  12 12 48
# Reading: 0 Writing: 1 Waiting: 2
```

**2. Check Elastic Agent logs for NGINX metrics:**
```bash
kubectl logs -n monitoring -l app=elastic-agent --prefix \
  | grep -i nginx | tail -20
```

**3. Count NGINX metric documents:**
```bash
curl -sk -u elastic:<ES_PASSWORD> \
  https://localhost:9200/metrics-nginx.*/_count \
  | python3 -m json.tool
# Expect: "count" > 0
```

**4. Verify structured JSON access logs from NGINX:**
```bash
kubectl logs -n ingress-nginx \
  $(kubectl get pod -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -o name | head -1) \
  | head -5
# Expected: JSON lines with "status", "request", "upstream_addr", "bytes_sent", etc.
```

**5. Kibana:**
- **Discover > `metrics-nginx.*`** -- fields like `nginx.stubstatus.active`, `nginx.stubstatus.requests`
- **Discover > `filebeat-*` or `logs-*`** -- filter `kubernetes.labels.app.kubernetes.io/name : ingress-nginx`

---

### Distributed Traces (APM)

**Goal:** OTLP traces from all 10 microservices flow through the OTel Gateway (with tail-based sampling) to APM Server and are visible in the Kibana APM UI.

**1. Confirm ENABLE_TRACING is set on all services:**
```bash
for svc in frontend cartservice checkoutservice currencyservice shippingservice \
           recommendationservice emailservice adservice productcatalogservice paymentservice; do
  echo -n "$svc: "
  kubectl get deploy/$svc -n online-boutique \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ENABLE_TRACING")].value}' 2>/dev/null \
    || echo "(no ENABLE_TRACING -- Java uses OTEL_ vars directly)"
  echo
done
# Expected: "1" for all Go/Node/Python services; adservice has OTEL_EXPORTER_OTLP_ENDPOINT instead
```

**2. Confirm the OTel Gateway is receiving spans:**
```bash
kubectl logs -n otel-system -l app=opentelemetry-collector \
  --selector='component=gateway' --prefix \
  | grep -i "span\|trace\|export" | tail -20
```

**3. Count trace documents in Elasticsearch:**
```bash
curl -sk -u elastic:<ES_PASSWORD> \
  https://localhost:9200/traces-apm.*/_count \
  | python3 -m json.tool
# Expect: "count" in the thousands (grows with traffic)
```

**4. Kibana -- APM Service Map:**
- **Observability > APM > Service Map** -- should show all 10 services interconnected
- **Observability > APM > Services** -- click any service to see latency/throughput/error rate
- **Observability > APM > Traces** -- individual trace waterfall view

---

### Alerting Rules

**Goal:** 11 alerting rules created via the Kibana API cover CPU, memory, disk, PostgreSQL I/O, Redis memory, NGINX error rate, and pod restart events.

**1. List rules via the Kibana API:**
```bash
curl -sk -u elastic:<ES_PASSWORD> \
  http://kibana.<IP>.nip.io/api/alerting/rules/_find?per_page=20 \
  | python3 -m json.tool | grep '"name"'
# Expected: 11 rules listed
```

**2. Kibana UI:**
- **Stack Management > Rules** -- all 11 rules show status "OK" or "Active"

**3. Trigger the CPU alert (optional smoke test):**
```bash
# Run a CPU stress pod to push CPU above 80%
kubectl run cpu-stress -n online-boutique \
  --image=progrium/stress \
  --restart=Never \
  -- stress --cpu 4 --timeout 120s

# Watch alert status
watch -n 10 'curl -sk -u elastic:<ES_PASSWORD> \
  http://kibana.<IP>.nip.io/api/alerting/rules/_find \
  | python3 -m json.tool | grep -A2 "CPU\|status"'

# Clean up
kubectl delete pod cpu-stress -n online-boutique
```

---

### RUM -- Real User Monitoring

> **RUM requires a custom frontend Docker image** (inject the APM JS snippet into the HTML template). Steps below.

**1. Confirm APM Server has RUM enabled:**
```bash
kubectl get configmap apm-server-config -n elastic -o yaml | grep -i rum
# Expected: "rum.enabled: true"

# Or check APM Server log
kubectl logs -n elastic -l app=apm-server --prefix | grep -i rum | head -5
```

**2. Confirm APM Server is reachable from the public internet:**
```bash
curl -s https://apm.<IP>.nip.io/ | head -5
# Expected: APM Server JSON info response (version, build_date, etc.)
```

**3. Build and deploy the RUM-enabled frontend image:**
```bash
# a. Clone the upstream repo at the matching tag
git clone --depth 1 --branch v0.10.5 \
  https://github.com/GoogleCloudPlatform/microservices-demo.git /tmp/ob

# b. Inject the RUM snippet just before </body> in the footer template
RUM_SNIPPET=$(cat rum/rum-init.html)
FOOTER=/tmp/ob/src/frontend/templates/footer.html

# Replace the placeholder IP with the real NGINX IP
INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
sed -i "s/INGRESS_IP_PLACEHOLDER/${INGRESS_IP}/g" rum/rum-init.html

# Append snippet before </body>
sed -i "s|</body>|$(cat rum/rum-init.html)\n</body>|" "$FOOTER"

# c. Build and push (replace <registry> with your ACR/DockerHub)
docker build -t <registry>/frontend-rum:v0.10.5 /tmp/ob/src/frontend/
docker push <registry>/frontend-rum:v0.10.5

# d. Roll out to the cluster
kubectl set image deployment/frontend \
  server=<registry>/frontend-rum:v0.10.5 \
  -n online-boutique

kubectl rollout status deployment/frontend -n online-boutique
```

**4. Verify RUM events in Kibana:**
- Open `http://<IP>.nip.io` in a browser
- **Observability > APM > User Experience** -- page load times, Core Web Vitals (LCP, FID, CLS)
- **Discover > `apm-*`** -- filter `processor.name: transaction` and `transaction.type: page-load`

**5. Quick browser console test (no image build needed):**
```javascript
// Paste in DevTools console on any page of the Online Boutique
var script = document.createElement('script');
script.src = 'https://unpkg.com/@elastic/apm-rum@5.12.0/dist/bundles/elastic-apm-rum.umd.min.js';
script.onload = function() {
  elasticApm.init({
    serviceName: 'online-boutique-rum-test',
    serverUrl: 'https://apm.<IP>.nip.io',
    environment: 'production'
  });
  console.log('RUM agent initialized -- check APM > User Experience in Kibana');
};
document.head.appendChild(script);
```

---

## Telemetry Signal Summary

| Signal | Source | Collector | Index Pattern | Assessment Section |
|--------|--------|-----------|---------------|-------------------|
| Host CPU / Memory / Disk / Net | OTel hostmetrics receiver | OTel Agent -> Gateway -> APM Server | `metrics-apm.*` | 3.1 |
| App Traces (spans) | OTLP from 10 microservices | OTel Agent -> Gateway -> APM Server | `traces-apm.*` | 3.1 / APM |
| App Metrics (runtime) | OTLP from services | OTel Agent -> Gateway -> APM Server | `metrics-apm.*` | 3.1 |
| PostgreSQL metrics | Elastic Agent integration | Elastic Agent DaemonSet -> ES direct | `metrics-postgresql.*` | 3.2 |
| Redis metrics | Elastic Agent integration | Elastic Agent DaemonSet -> ES direct | `metrics-redis.*` | 3.2 |
| kube-audit logs | Filebeat DaemonSet | Filebeat -> Logstash/ES direct | `filebeat-*` | 3.3 |
| NGINX access logs | NGINX structured JSON | Elastic Agent / Filebeat | `logs-*` | 3.4 |
| NGINX stub_status metrics | Elastic Agent NGINX integration | Elastic Agent DaemonSet -> ES direct | `metrics-nginx.*` | 3.4 |
| RUM page-load events | APM RUM JS agent in browser | Browser -> APM Server | `apm-*` | RUM |

---

## Alerting Rules Reference

| # | Rule Name | Signal | Threshold | Severity |
|---|-----------|--------|-----------|----------|
| 1 | High CPU Usage | `system.cpu.total.pct` | > 0.80 for 5 min | Warning |
| 2 | High Memory Usage | `system.memory.used.pct` | > 0.85 for 5 min | Warning |
| 3 | High Disk Usage | `system.filesystem.used.pct` | > 0.85 | Critical |
| 4 | Pod Restarts | `kubernetes.pod.status.restarts` | > 5 in 10 min | Warning |
| 5 | High PostgreSQL Disk I/O | `postgresql.bgwriter.buffers.clean` (doc count) | count > 0 per 5 min | Warning |
| 6 | High Redis Memory | `redis.info.memory.used.value` | > 200 MB (209715200 bytes) | Warning |
| 7 | High Request Latency | APM `transaction.duration.us` | p95 > 1000 ms | Warning |
| 8 | High Error Rate | APM `transaction.result` = error | > 5% over 5 min | Critical |
| 9 | NGINX 5xx Errors | `http.response.status_code` >= 500 (log count) | count > 0 per 5 min | Warning |
| 10 | Service Unavailable | APM `service.name` no heartbeat | 0 transactions in 5 min | Critical |
| 11 | High Network I/O | `system.network.in.bytes` delta | > 100 MB/min | Warning |

---

## Bugs Fixed in This Implementation

| # | File | Bug | Fix Applied |
|---|------|-----|-------------|
| 1 | `otel-collector/values-agent.yaml` | Duplicate `receivers:` YAML key -- second block silently dropped, hostmetrics never collected | Merged into single block; added `metrics:` and `logs:` pipelines wiring hostmetrics |
| 2 | `infrastructure/alerting-rules/create-alerting-rules.sh` | Script truncated mid-JSON at line 299 -- Rule 11 unclosed string caused CI hang | Completed Rule 11 body + added summary footer |
| 3 | `infrastructure/alerting-rules/create-alerting-rules.sh` | Rule 5 used wrong Elastic field `blks_hit` ratio -- alert never fired on disk I/O | Fixed to `logs.alert.document.count` on `blks_read > 0` |
| 4 | `infrastructure/alerting-rules/create-alerting-rules.sh` | Rule 6 used `memory.used.peak > 0.85` (fraction) -- Redis memory alert never fired | Fixed to `redis.info.memory.used.value > 209715200` (bytes) |
| 5 | `infrastructure/alerting-rules/create-alerting-rules.sh` | Rule 9 used `stubstatus.requests > 0.05` -- NGINX error alert matched all traffic | Fixed to log-count query on `status_code >= 500` |
| 6 | `kubernetes/nginx-ingress/nginx-values.yaml` | Duplicate `config:` key -- `allow-snippet-annotations` was silently dropped | Merged into single `config:` block |
| 7 | `kubernetes/nginx-ingress/nginx-values.yaml` | `enable-opentelemetry: "true"` with no OTLP backend -- constant error log spam | Removed the flag |
| 8 | `instrumentation/` | Patch files existed for only 3 of 10 services -- 7 services sent zero telemetry | Created `k8s-patch.yaml` for checkout, currency, shipping, recommendation, email, adservice, productcatalog |
| 9 | `kubernetes/monitoring/` | `elastic-agent-config.yaml` (ConfigMap only) -- no agent ran it; zero DB/NGINX metrics | Created `elastic-agent-daemonset.yaml` with full DaemonSet manifest |
| 10 | `.github/workflows/2-deploy-observability.yml` | `kibana.yaml` publicBaseUrl had literal `INGRESS_IP_PLACEHOLDER` -- never replaced | Added `kubectl patch kibana` step after NGINX IP is obtained |
| 11 | `kubernetes/cluster-setup.sh` / `namespaces.yaml` | `ingress-nginx` namespace missing `kubernetes.io/metadata.name` label -- NetworkPolicy `namespaceSelector` never matched | Added namespace entry with required label to `namespaces.yaml` |

---

## Tear Down

Run the **Destroy All Resources** workflow from the GitHub Actions tab.
When prompted, type `destroy` to confirm.

This deletes the entire Azure Resource Group (`sre-assessment-rg`) including:
- AKS cluster, node pool VMs
- Azure Load Balancer and public IP
- All Elasticsearch data (permanent, no backup)
- Persistent volume disks

**Estimated monthly cost while running:** ~$350-400 USD (2 x Standard_D4ads_v6 nodes + storage + load balancer in `northeurope`). Destroy when not in use.
