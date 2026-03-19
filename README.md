# SRE Practical Assessment — Complete Implementation

Production-grade observability platform for Google's [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) (11 polyglot microservices) using **Elastic Stack** + **OpenTelemetry** on **Azure Kubernetes Service (AKS)**, deployed via **GitHub Actions**.

---

## How Everything Connects (Architecture)

```
┌─────────────────────────────────────────────────────────────────┐
│ BROWSER (User's computer)                                       │
│                                                                 │
│  Online Boutique UI ◄──── HTML pages served by frontend         │
│  Elastic APM RUM Agent ──── sends page load + Web Vitals ──┐   │
│  (rum-init.html)            via HTTP to APM Server          │   │
└──────────────────┬──────────────────────────────────────────┼───┘
                   │ HTTP requests                            │ RUM data
                   ▼                                          ▼
┌──────────────────────────────────────────────────────────────────┐
│ AZURE LOAD BALANCER (Public IP: x.x.x.x)                        │
│ Created automatically by NGINX Ingress Controller                │
│ Routes: *.nip.io hostnames → correct backend services            │
│   x.x.x.x.nip.io      → frontend                               │
│   kibana.x.x.x.x.nip.io → Kibana                               │
│   apm.x.x.x.x.nip.io    → APM Server (for browser RUM)         │
└──────────────────┬───────────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────────┐
│ AKS CLUSTER (2 nodes × 4 vCPU × 16GB RAM)                       │
│                                                                   │
│ ┌─── Namespace: online-boutique ───────────────────────────────┐ │
│ │                                                               │ │
│ │  frontend ◄──► checkoutservice ──► paymentservice (Node.js)  │ │
│ │  (Go)           (Go)                                          │ │
│ │    │                │              shippingservice (Go)       │ │
│ │    │                │              emailservice (Python)      │ │
│ │    ▼                ▼              currencyservice (Node.js)  │ │
│ │  cartservice ──► redis-cart       recommendationservice (Py)  │ │
│ │  (C#/.NET)                        adservice (Java)           │ │
│ │                                   loadgenerator (Python)     │ │
│ │  postgresql (added for DB monitoring)                        │ │
│ │                                                               │ │
│ │  Each instrumented service has env var:                       │ │
│ │  OTEL_EXPORTER_OTLP_ENDPOINT → OTel Agent on port 4317      │ │
│ └───────────────────────────┬───────────────────────────────────┘ │
│                             │ OTLP gRPC (port 4317)              │
│                             ▼                                     │
│ ┌─── Namespace: otel-system ───────────────────────────────────┐ │
│ │                                                               │ │
│ │  OTel Agent (DaemonSet — 1 per node)                         │ │
│ │    Receives: OTLP from app pods + hostmetrics from node      │ │
│ │    Enriches: adds pod name, namespace, deployment (K8s API)  │ │
│ │    Forwards: everything to OTel Gateway                      │ │
│ │                    │                                          │ │
│ │                    ▼                                          │ │
│ │  OTel Gateway (Deployment — 1 central instance)              │ │
│ │    Receives: all data from all Agents                        │ │
│ │    Samples:  100% errors, 100% slow >1s, 10% healthy         │ │
│ │    Exports:  OTLP HTTP → APM Server                          │ │
│ └───────────────────────────┬───────────────────────────────────┘ │
│                             │ OTLP HTTP (port 8200)              │
│                             ▼                                     │
│ ┌─── Namespace: elastic ───────────────────────────────────────┐ │
│ │                                                               │ │
│ │  APM Server ──► Elasticsearch ◄── Kibana                     │ │
│ │  (receives       (stores all       (visualizes                │ │
│ │   traces +        traces/metrics/   data in                   │ │
│ │   RUM data)       logs)             dashboards)               │ │
│ │                                                               │ │
│ │  Fleet Server (manages Elastic Agent policies)               │ │
│ └───────────────────────────────────────────────────────────────┘ │
│                                                                   │
│ ┌─── Namespace: monitoring ────────────────────────────────────┐ │
│ │  Filebeat (Calico flow logs → Elasticsearch)                 │ │
│ │  Filebeat (K8s audit logs → Elasticsearch)                   │ │
│ └───────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────┘
```

---

## Where Is the Application?

The **application** is Google's [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) — a sample e-commerce app with 11 microservices written in Go, C#, Node.js, Python, and Java.

**We do NOT clone the application repo.** Instead:
1. The application's Kubernetes manifests are **vendored** (copied) into [kubernetes/application/online-boutique.yaml](kubernetes/application/online-boutique.yaml)
2. The **Docker images** are pre-built by Google and pulled directly from Google Artifact Registry at deploy time
3. We **configure** the application by patching environment variables (in [instrumentation/*/k8s-patch.yaml](instrumentation/)) that tell the OTel SDK where to send telemetry

Think of it like this: Google built and packaged the app. We deploy their packages and wire up monitoring.

---

## How to Deploy (GitHub Actions)

### Prerequisites
1. An Azure subscription
2. A GitHub repository with this code
3. An Azure service principal (for GitHub Actions to authenticate):

```bash
# Create service principal and save the JSON output
az ad sp create-for-rbac \
  --name "github-sre-assessment" \
  --role contributor \
  --scopes /subscriptions/<YOUR-SUBSCRIPTION-ID> \
  --sdk-auth
```

4. Add the JSON output as a GitHub secret named `AZURE_CREDENTIALS`:
   - Go to: GitHub repo → Settings → Secrets and variables → Actions
   - Click "New repository secret"
   - Name: `AZURE_CREDENTIALS`
   - Value: paste the entire JSON from step 3

### Deployment Steps

Run these workflows **in order** from GitHub Actions tab:

| Step | Workflow | What it does | Time |
|------|----------|-------------|------|
| 1 | **1 - Deploy Infrastructure** | Creates AKS cluster, namespaces, ECK operator | ~10 min |
| 2 | **2 - Deploy Observability Stack** | Deploys Elastic Stack, OTel Collectors, NGINX Ingress | ~10 min |
| 3 | **3 - Deploy Application** | Deploys Online Boutique, monitoring, alerting rules | ~5 min |

### After Deployment

```bash
# Get cluster credentials locally
az aks get-credentials -g sre-assessment-rg -n sre-assessment-aks

# Get the Ingress IP
kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Get Elasticsearch password
kubectl get secret elasticsearch-es-elastic-user -n elastic -o jsonpath='{.data.elastic}' | base64 -d
```

Access URLs (replace `<IP>` with your Ingress IP):
- **Online Boutique**: `http://<IP>.nip.io`
- **Kibana**: `http://kibana.<IP>.nip.io` (login: elastic / `<password>`)
- **APM Server**: `http://apm.<IP>.nip.io`

### Tear Down

Run the **🗑️ Destroy All Resources** workflow (type "destroy" to confirm).

---

## Repository Structure

```
.github/workflows/
  1-deploy-infrastructure.yml  ← Step 1: AKS cluster + ECK operator
  2-deploy-observability.yml   ← Step 2: Elastic Stack + OTel + NGINX
  3-deploy-application.yml     ← Step 3: App + monitoring + alerts
  destroy.yml                  ← Tear down everything

kubernetes/
  base/
    namespaces.yaml            ← 4 namespaces for isolation
  elastic-stack/
    elasticsearch.yaml         ← Data store (traces, metrics, logs)
    kibana.yaml                ← Visualization UI
    apm-server.yaml            ← Receives OTLP + RUM data
    fleet-server.yaml          ← Manages Elastic Agents
  otel-collector/
    agent-values.yaml          ← Per-node DaemonSet (collection + enrichment)
    gateway-values.yaml        ← Central Deployment (sampling + export)
  application/
    online-boutique.yaml       ← 11 microservices (vendored from Google)
    postgresql.yaml            ← Database for monitoring (Section 3.2)
  ingress/
    nginx-values.yaml          ← NGINX Ingress Controller config
    frontend-ingress.yaml      ← Routes traffic to frontend
    kibana-ingress.yaml        ← Routes traffic to Kibana + APM Server
  network-policies/
    policies.yaml              ← 8 network policies (default-deny + allow-list)
    calico-flow-logs.yaml      ← Ships Calico flow logs to Elasticsearch
  monitoring/
    kube-audit-filebeat.yaml   ← Ships K8s audit logs to Elasticsearch
    elastic-agent-config.yaml  ← System, PostgreSQL, Redis, NGINX metrics
  alerting/
    create-alerting-rules.sh   ← 11 rules created via Kibana API

instrumentation/
  frontend/k8s-patch.yaml      ← OTel env vars for frontend (Go)
  cartservice/k8s-patch.yaml   ← OTel env vars for cartservice (C#)
  paymentservice/k8s-patch.yaml← OTel env vars for paymentservice (Node.js)
  rum/rum-init.html            ← Browser RUM Agent configuration

dashboards/
  DASHBOARD-GUIDE.md           ← Panel-by-panel creation instructions

scripts/
  generate-traffic.sh          ← Simulates shopping sessions for testing

docs/
  DECISIONS.md                 ← 10 architectural decisions with rationale
```

---

## Telemetry Collection Explained

### Traces (Distributed Tracing)
**Flow:** App pod → OTel Agent → OTel Gateway (sampling) → APM Server → Elasticsearch

When a user visits the store:
1. Browser sends HTTP request to frontend
2. Frontend creates a trace span, calls cartservice via gRPC
3. `traceparent` header propagates the trace ID across services
4. Each service adds its span to the trace
5. OTel SDK sends spans to OTel Agent (same node, port 4317)
6. Agent enriches with K8s metadata (pod name, namespace)
7. Agent forwards to Gateway
8. Gateway applies tail-based sampling (keep errors/slow/10% healthy)
9. Gateway exports to APM Server via OTLP HTTP
10. APM Server indexes into Elasticsearch
11. Viewable in Kibana APM as a trace waterfall

### Metrics
**Flow:** OTel Agent (hostmetrics) + Elastic Agent (integrations) → Elasticsearch

- **Host metrics**: CPU, memory, disk, network — collected by OTel Agent's hostmetrics receiver every 30s
- **PostgreSQL**: Connections, cache hit ratio, slow queries — collected by Elastic Agent PostgreSQL integration
- **Redis**: Memory, clients, evictions — collected by Elastic Agent Redis integration
- **NGINX**: Request rates, latency, status codes — collected from Prometheus metrics endpoint
- **Custom app metrics**: cart_operations_total, payment_attempts_total — sent via OTLP from app SDKs

### Logs
**Flow:** Filebeat DaemonSet → Elasticsearch

- **Calico flow logs**: Every allowed/denied network connection → shipped by Filebeat
- **K8s audit logs**: Network policy changes → shipped by Filebeat
- **Application logs**: Collected by OTel Agent from pod stdout

---

## Alerting Rules (11 Total)

| # | Rule | Threshold | Section |
|---|------|-----------|---------|
| 1 | High CPU Usage | > 85% for 5 min | 3.1 Compute |
| 2 | Disk Space Critical | > 90% used | 3.1 Compute |
| 3 | Memory Pressure | < 500MB available | 3.1 Compute |
| 4 | PostgreSQL Connections | > 80% of max (100) | 3.2 Database |
| 5 | PostgreSQL Cache Hit Ratio | < 95% | 3.2 Database |
| 6 | Redis Memory | > 85% of max | 3.2 Database |
| 7 | Redis Eviction Rate | > 100 keys/5min | 3.2 Database |
| 8 | Unexpected Egress | Any denied connection | 3.3 Network |
| 9 | 5xx Error Rate | > 5% over 2 min | 3.4 NGINX |
| 10 | Backend Errors (502/503) | > 3 in 2 min | 3.4 NGINX |
| 11 | SSL Certificate Expiry | < 14 days | 3.4 NGINX |

---

## Network Connectivity

All traffic enters through a single **Azure Load Balancer** public IP, managed by the NGINX Ingress Controller. Internal communication uses Kubernetes DNS (ClusterIP services). Network policies enforce:

- **Default deny** all ingress to application namespace
- **Explicit allow** only required service-to-service paths
- **OTel egress** allowed for all pods to send telemetry
- **Calico flow logs** capture all allowed/denied connections

No port-forwarding is needed — everything is accessible via the public IP.
