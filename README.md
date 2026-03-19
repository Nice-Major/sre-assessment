# SRE Practical Assessment — Full Implementation

Production-grade observability and infrastructure monitoring for the Google Online Boutique (11 polyglot microservices) using **Elastic Stack** and **OpenTelemetry**, deployed on **Azure Kubernetes Service (AKS)**.

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│  Browser (RUM)                                                       │
│  @elastic/apm-rum → APM Server                                       │
└──────────────┬───────────────────────────────────────────────────────┘
               │ (distributed tracing headers)
┌──────────────▼───────────────────────────────────────────────────────┐
│  NGINX Ingress Controller                                             │
│  metrics → Elastic Agent │ access logs → JSON structured              │
└──────────────┬───────────────────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────────────────┐
│  Online Boutique Microservices (online-boutique namespace)            │
│                                                                       │
│  ┌────────────┐  ┌──────────────┐  ┌────────────────┐               │
│  │ frontend   │  │ cartservice  │  │ paymentservice │               │
│  │ (Go+OTel)  │  │ (C#+OTel)   │  │ (Node.js+OTel) │               │
│  └────┬───────┘  └──────┬───────┘  └────────┬───────┘               │
│       │                  │                    │                       │
│       │     ┌────────────▼──┐                 │                       │
│       │     │ Redis (cart)  │                 │                       │
│       │     └───────────────┘                 │                       │
│       │                                       │                       │
│  + productcatalog, currency, shipping, checkout, recommendation,     │
│    ad, email, loadgenerator + PostgreSQL (for monitoring)            │
└──────┬─────────────────────┬─────────────────┬───────────────────────┘
       │ OTLP (gRPC:4317)   │                  │
┌──────▼─────────────────────▼──────────────────▼──────────────────────┐
│  OTel Collector — Agent (DaemonSet, per node)                        │
│  receivers: OTLP, Zipkin, hostmetrics                                │
│  processors: memory_limiter, k8sattributes, resourcedetection, batch│
│  exports → Gateway                                                    │
└──────────────────────────┬───────────────────────────────────────────┘
                           │ OTLP (gRPC:4317)
┌──────────────────────────▼───────────────────────────────────────────┐
│  OTel Collector — Gateway (Deployment)                                │
│  processors: memory_limiter, tail_sampling, batch                    │
│  exports → Elastic APM Server (OTLP HTTP :8200)                      │
└──────────────────────────┬───────────────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────────────┐
│  Elastic Stack (elastic namespace, managed by ECK)                    │
│  ┌─────────────┐  ┌────────┐  ┌────────────┐  ┌─────────────────┐   │
│  │Elasticsearch│  │ Kibana │  │ APM Server │  │ Fleet Server    │   │
│  │ (HTTPS/TLS) │  │ (UI)   │  │ (OTLP+RUM) │  │ (agent mgmt)   │   │
│  └─────────────┘  └────────┘  └────────────┘  └─────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Azure CLI | 2.x | https://docs.microsoft.com/cli/azure/install-azure-cli |
| kubectl | 1.32+ | https://kubernetes.io/docs/tasks/tools/ |
| Helm | 3.14+ | https://helm.sh/docs/intro/install/ |
| GitHub CLI | 2.x | https://cli.github.com/ |

**Azure resources:**
- AKS cluster: 2x Standard_D4ads_v6 (4 vCPU, 16 GB RAM each)
- Region: North Europe
- Network Policy: Calico
- Kubernetes: v1.32

## Quick Start

### Azure AKS Deployment:
```bash
# 1. Login to Azure
az login

# 2. Provision AKS cluster
bash scripts/provision-aks.sh

# 3. Deploy everything
bash scripts/deploy-all.sh
```

This deploys everything in order (takes ~15-20 minutes):
1. AKS cluster with 2 nodes and Calico CNI
2. Elastic Stack (Elasticsearch, Kibana, APM Server, Fleet Server) via ECK
3. NGINX Ingress Controller
4. Google Online Boutique + PostgreSQL
5. OpenTelemetry Collector (Gateway + Agent)
6. Network Policies
7. Infrastructure monitoring collectors
8. Service instrumentation patches

### Step-by-step deployment:
```bash
# 1. Create cluster
bash kubernetes/cluster-setup.sh

# 2. Deploy Elastic Stack
bash kubernetes/elastic-stack/deploy-elastic-stack.sh

# 3. Deploy NGINX Ingress
bash kubernetes/nginx-ingress/deploy-nginx-ingress.sh

# 4. Deploy Online Boutique + PostgreSQL
bash kubernetes/online-boutique/deploy-online-boutique.sh

# 5. Deploy OTel Collectors
bash otel-collector/deploy-otel-collector.sh

# 6. Apply network policies
kubectl apply -f infrastructure/network-policies/network-policies.yaml

# 7. Deploy infrastructure monitoring
kubectl apply -f infrastructure/network-policies/calico-flow-logs.yaml
kubectl apply -f infrastructure/network-policies/kube-audit-filebeat.yaml

# 8. Apply instrumentation patches
kubectl patch deployment frontend -n online-boutique --patch-file instrumentation/frontend/k8s-patch.yaml
kubectl patch deployment cartservice -n online-boutique --patch-file instrumentation/cartservice/k8s-patch.yaml
kubectl patch deployment paymentservice -n online-boutique --patch-file instrumentation/paymentservice/k8s-patch.yaml
```

## Accessing Services

All services are exposed via the NGINX Ingress Controller at the cluster's external IP.
No port-forwarding required.

| Service | URL | Notes |
|---|---|---|
| **Online Boutique** | `http://<INGRESS_IP>` | Direct access via public IP |
| **Kibana** | `http://kibana.<INGRESS_IP>.nip.io` | Login: elastic / `<password>` |
| **APM Server** | `http://apm.<INGRESS_IP>.nip.io` | For RUM browser agent |

> `nip.io` is a wildcard DNS that resolves `*.IP.nip.io` to that IP. No `/etc/hosts` changes needed.

**Get the Ingress IP:**
```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

**Kibana credentials:**
```bash
# Username: elastic
# Password:
kubectl get secret elasticsearch-es-elastic-user -n elastic -o jsonpath='{.data.elastic}' | base64 -d
```

## Post-Deployment Steps

### 1. Generate traffic
```bash
bash scripts/generate-traffic.sh 100    # 100 checkout flows
bash scripts/generate-traffic.sh continuous  # run indefinitely
```

### 2. Configure Fleet Agent integrations
Open Kibana → Fleet → Agent policies and configure:
- System integration (see `infrastructure/elastic-agent-policies/system-policy.yaml`)
- PostgreSQL integration (see `infrastructure/postgres-integration/postgresql-config.yaml`)
- Redis integration (see `infrastructure/redis-integration/redis-config.yaml`)
- NGINX integration (see `infrastructure/nginx-integration/nginx-config.yaml`)

### 3. Create alerting rules
```bash
# Uses Ingress-based Kibana URL
INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
KIBANA_URL="http://kibana.${INGRESS_IP}.nip.io" bash infrastructure/alerting-rules/create-alerting-rules.sh
```

### 4. Create dashboards
Follow the guide in `dashboards/DASHBOARD-GUIDE.md` to create the three required dashboards in Kibana.

### 5. Export dashboards
```bash
INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
KIBANA_URL="http://kibana.${INGRESS_IP}.nip.io" bash scripts/export-dashboards.sh
```

## Verification Checklist

### Section 1: OpenTelemetry Implementation
- [ ] OTel Agent DaemonSet running on all 2 nodes: `kubectl get pods -n otel-system -o wide`
- [ ] OTel Gateway running: `kubectl get pods -n otel-system`
- [ ] Services visible in Kibana → Observability → APM → Services
- [ ] Traces visible in Kibana → Observability → APM → Traces
- [ ] Service Map shows connected services: Kibana → APM → Service Map
- [ ] Custom spans visible on transactions (validate-cart-contents, process-payment-charge, etc.)
- [ ] Custom metrics queryable in Kibana → Observability → Metrics Explorer
- [ ] Collector health via zpages (accessible inside cluster or via port-forward if needed)

### Section 2: RUM + Dashboards
- [ ] RUM data in Kibana → Observability → User Experience
- [ ] Core Web Vitals visible (LCP, FID, CLS, TTFB)
- [ ] Browser-to-backend trace correlation in APM → Traces
- [ ] Dashboard 1: Service Health Overview (exported as NDJSON)
- [ ] Dashboard 2: RUM Performance (exported as NDJSON)
- [ ] Dashboard 3: Business Transaction Monitoring (exported as NDJSON)

### Section 3: Infrastructure Monitoring
- [ ] Host metrics in Kibana → Observability → Infrastructure → Inventory
- [ ] PostgreSQL dashboard populated (Kibana → Dashboards → search "PostgreSQL")
- [ ] Redis dashboard populated (Kibana → Dashboards → search "Redis")
- [ ] Calico flow logs in Discover (index: logs-calico.flowlog-*)
- [ ] Network denied connections visible
- [ ] NGINX metrics and access logs flowing
- [ ] All 11 alerting rules created and active: Kibana → Observability → Rules
- [ ] NGINX ↔ backend latency correlation dashboard panel

## Repository Structure

```
sre-assessment/
├── otel-collector/                   # Section 1.1
│   ├── values-agent.yaml             # DaemonSet agent Helm values
│   ├── values-gateway.yaml           # Gateway Deployment Helm values
│   ├── sampling-policy.yaml          # Tail sampling rationale
│   └── deploy-otel-collector.sh
├── instrumentation/                  # Section 1.2
│   ├── frontend/                     # Go — otel_init.go, k8s-patch.yaml
│   ├── cartservice/                  # C# — OtelConfig.cs, k8s-patch.yaml
│   └── paymentservice/              # Node.js — tracing.js, custom-spans.js, k8s-patch.yaml
├── rum/                              # Section 2.1
│   ├── rum-init.html                 # Elastic RUM agent script block
│   └── README.md
├── dashboards/                       # Section 2.2
│   ├── DASHBOARD-GUIDE.md            # Panel-by-panel creation instructions
│   ├── service-health.ndjson         # Exported after creation
│   ├── rum-performance.ndjson
│   └── business-transactions.ndjson
├── infrastructure/                   # Section 3
│   ├── elastic-agent-policies/       # System integration config
│   ├── postgres-integration/         # PostgreSQL monitoring config
│   ├── redis-integration/            # Redis monitoring config
│   ├── nginx-integration/            # NGINX Ingress monitoring config
│   ├── network-policies/             # NetworkPolicies + Calico flow logs + audit
│   └── alerting-rules/              # Kibana alerting rule creation script
├── kubernetes/                       # Cluster + stack deployment
│   ├── cluster-setup.sh
│   ├── elastic-stack/               # ECK CRDs + deploy script
│   ├── nginx-ingress/               # Ingress controller + frontend Ingress
│   └── online-boutique/             # App manifests + PostgreSQL StatefulSet
├── scripts/
│   ├── deploy-all.sh                # One-command full deployment
│   ├── generate-traffic.sh          # Checkout flow traffic generator
│   └── export-dashboards.sh         # Kibana NDJSON exporter
├── docs/
│   └── DECISIONS.md                 # Architectural decision log (10 decisions)
└── README.md                        # This file
```

## Known Limitations

1. **Single-node Elasticsearch:** Sufficient for assessment; not HA. Production would use 3+ nodes.
2. **AKS resource constraints:** 2 nodes with 4 vCPU each. Monitor with `kubectl top nodes`.
3. **Custom instrumentation requires image rebuild:** The OTel SDK code (otel_init.go, OtelConfig.cs, tracing.js) must be compiled into new Docker images. K8s patches inject env vars but the SDK init code needs to be in the image.
4. **RUM APM Server:** Exposed via Ingress at `http://apm.<INGRESS_IP>.nip.io` for browser-to-backend tracing.
5. **Calico flow logs:** Depend on Calico CNI being properly installed. If using a different CNI, flow log collection will need adaptation.
6. **Dashboard NDJSON files:** Placeholder until dashboards are created in Kibana and exported. Run `scripts/export-dashboards.sh` after building dashboards.
