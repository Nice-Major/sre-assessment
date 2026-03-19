# Architectural Decision Log

This document records the key architectural and implementation decisions made during the SRE practical assessment. Each decision includes context, the choice made, and the rationale.

---

## Decision 1: Kubernetes Cluster — Azure AKS with Calico CNI

**Context:** The assessment requires a multi-node cluster with the ability to run Elastic Stack, 11 microservices, OpenTelemetry collectors, NGINX Ingress, and monitoring agents simultaneously.

**Decision:** Use Azure Kubernetes Service (AKS) with 2 nodes (Standard_D4ads_v6, 4 vCPU / 16 GB each), Calico CNI, and managed identity.

**Rationale:**
- AKS provides a production-grade managed Kubernetes environment
- Calico CNI is required for Section 3.3 (Network Policy monitoring with flow logs)
- Standard_D4ads_v6 provides a good balance of compute and memory for the workload
- Managed identity simplifies Azure RBAC and avoids credential management
- 2 nodes with 4 vCPU each provides 8 vCPUs total, sufficient for all workloads
- Region: North Europe (selected for subscription availability)

**Trade-offs:**
- Cloud costs (~$0.40/hour) vs. free local minikube
- 2 nodes (not 3+) due to subscription quota constraints; acceptable for assessment
- Free tier AKS has no SLA; acceptable for assessment scope

---

## Decision 2: OTel Collector Topology — Gateway + Agent (DaemonSet)

**Context:** Section 1.1 requires both DaemonSet agents and a central gateway, with tail-based sampling at the gateway level.

**Decision:** Deploy OTel Collector in a 2-tier topology:
- DaemonSet agents (one per node) receive telemetry from application SDKs, enrich with k8s attributes, and forward to the gateway
- Gateway Deployment (single replica) applies tail-based sampling on traces and exports all signals to Elastic APM Server via OTLP

**Rationale:**
- Agent per node minimizes network hops from application pods to collector
- Gateway centralizes sampling decisions (tail-based sampling requires seeing all spans of a trace in one place)
- Separating concerns: agents handle collection + enrichment, gateway handles sampling + export
- This is the canonical OTel deployment pattern for production environments

**Trade-offs:**
- Additional hop (agent → gateway) adds minimal latency (~1-2ms)
- Single gateway replica is a SPOF; in production, scale to 2+ replicas with a headless service
- Memory usage: gateway needs to buffer traces during the `decision_wait` window (10s)

---

## Decision 3: Tail-Based Sampling Policy

**Context:** Sampling must balance observability coverage with storage efficiency.

**Decision:** Three-tier sampling policy:
1. Always keep 100% of error traces
2. Always keep 100% of high-latency traces (>1000ms)
3. Probabilistic 10% sampling of remaining healthy traces

**Rationale:**
- Errors are rare but critical — never sample them away
- High-latency traces signal performance issues — always keep
- 10% of healthy traffic provides sufficient statistical visibility for dashboards and service maps
- Expected storage reduction: 80-85%
- The 1000ms latency threshold is set above the p95 for most Online Boutique services under normal load

**Trade-offs:**
- 10% may miss rare but interesting normal-path traces; increase to 50% if storage is abundant
- `decision_wait: 10s` means traces arrive in Elastic with 10s additional delay
- For this short-lived assessment, could increase to 100% since storage pressure is low

---

## Decision 4: Service Selection for Instrumentation

**Context:** Section 1.2 requires instrumenting 3 services in 3 different languages.

**Decision:** Instrument frontend (Go), cartservice (C# .NET), and paymentservice (Node.js).

**Rationale:**
- **Three different languages** (Go, C#, JavaScript) — maximizes language diversity points
- **frontend (Go):** Entry point for all user traffic; tracing here captures the root span. Shows HTTP middleware + gRPC client instrumentation.
- **cartservice (C#):** Demonstrates .NET auto-instrumentation + Redis client tracing. Cart operations are a natural fit for business metrics (items added/removed).
- **paymentservice (Node.js):** Payment processing is business-critical. Node.js auto-instrumentation is robust. Custom spans around payment validation and charging are high-value.
- These three form a natural transaction path: frontend → cart → payment (checkout flow)

**Alternatives considered:**
- recommendationservice (Python) — good language choice but less business-critical
- currencyservice (C++) — manual OTel C++ SDK instrumentation is time-intensive; risky under time pressure
- emailservice (Ruby) — Ruby OTel ecosystem is less mature

---

## Decision 5: RUM Implementation — Elastic APM RUM Agent

**Context:** Section 2.1 allows either Elastic APM RUM Agent or OpenTelemetry Web SDK.

**Decision:** Use the Elastic APM RUM Agent (`@elastic/apm-rum`).

**Rationale:**
- Native integration with Kibana's User Experience dashboard — Core Web Vitals, geographic distribution, and session tracking work out of the box
- Browser-to-backend trace correlation is automatic when using the Elastic RUM agent with Elastic APM Server
- The Elastic RUM agent auto-captures page load, fetch/XHR, and user interactions
- OTel Web SDK would require more manual configuration for Kibana compatibility

**Trade-offs:**
- Vendor lock-in to Elastic RUM agent (not portable to non-Elastic backends)
- For an Elastic-stack assessment, this is the optimal choice

---

## Decision 6: Infrastructure Monitoring — Fleet-managed Elastic Agent

**Context:** Section 3 requires monitoring VMs, databases, network, and load balancers. Options: Fleet-managed Elastic Agent, standalone Beats, or OTel Collector hostmetrics.

**Decision:** Primary approach is Fleet-managed Elastic Agent with integrations (System, PostgreSQL, Redis, NGINX). OTel Collector hostmetrics as a supplementary source for node-level metrics (already configured in the DaemonSet agent).

**Rationale:**
- Fleet-managed approach centralizes agent policy management in Kibana
- Integration packages (PostgreSQL, Redis, NGINX) include pre-built dashboards, index templates, and field mappings
- System integration is the most feature-rich for host-level metrics in the Elastic ecosystem
- OTel hostmetrics on the DaemonSet provides defense-in-depth (two independent sources of node metrics)

**Trade-offs:**
- Fleet Server is another component to deploy and manage
- Elastic Agent's memory footprint is higher than standalone Filebeat/Metricbeat
- For this assessment, the richer Fleet UI and pre-built dashboards justify the overhead

---

## Decision 7: Calico for Network Policy Monitoring

**Context:** Section 3.3 requires network policy flow logs and denied connection monitoring.

**Decision:** Use Calico CNI (installed at cluster creation time) with flow log export to Elasticsearch via Filebeat.

**Rationale:**
- Calico is the most widely used CNI with network policy enforcement and flow logging
- Flow logs capture allowed/denied connections with source/destination pod metadata
- Filebeat DaemonSet ships flow logs to Elasticsearch in near-real-time
- Calico OSS supports basic flow logging; Calico Enterprise adds more granularity

**Trade-offs:**
- Calico OSS flow logging is less granular than Calico Enterprise or Cilium Hubble
- Flow log volume can be high in a busy cluster; batch/aggregate settings help

---

## Decision 8: Alerting Rule Thresholds

**Context:** Each infrastructure component requires meaningful alerting rules with thresholds that avoid noise but catch real issues.

**Decisions and rationale:**

| Rule | Threshold | Rationale |
|---|---|---|
| CPU sustained | >85% for 5 min | Brief spikes are normal; sustained high CPU signals saturation |
| Disk critical | >90% used | Industry standard; <10% free is danger zone |
| Memory pressure | <500MB available | Enough headroom to prevent OOM kills |
| PG connections | >80% of max (80/100) | Leave 20% buffer for admin connections and spikes |
| PG cache hit ratio | <95% | Below 95% indicates excessive disk reads; tune shared_buffers |
| Redis memory | >85% of maxmemory | Eviction starts when maxmemory is hit; alert early |
| Redis eviction rate | >100 keys/5min | Eviction indicates memory pressure or poor key TTL |
| NGINX 5xx rate | >5% over 2min | Some 5xx is normal; sustained >5% is an incident |
| NGINX 502/503 | >3 in 2min | Backend failure pattern |
| SSL cert expiry | <14 days | Two-week warning allows time for renewal |
| External egress | Any denied | Zero-trust: all external egress should be explicitly allowed |

---

## Decision 9: PostgreSQL Deployment

**Context:** The Online Boutique application doesn't include a PostgreSQL database, but Section 3.2 requires PostgreSQL monitoring.

**Decision:** Deploy a standalone PostgreSQL 16 StatefulSet in the online-boutique namespace with pg_stat_statements enabled and slow query logging configured.

**Rationale:**
- Demonstrates ability to add infrastructure components not present in the base application
- StatefulSet with PVC ensures data persistence across pod restarts
- pg_stat_statements extension provides the query statistics needed for slow query identification
- `log_min_duration_statement=200ms` captures queries that may impact user experience
- max_connections=100 allows meaningful connection pool monitoring

---

## Decision 10: Elastic Stack Version — 8.13.4

**Context:** Need a stable Elastic Stack version that supports OTLP intake, RUM, Fleet, and ML features.

**Decision:** Use Elastic Stack 8.13.4 consistently across all components (Elasticsearch, Kibana, APM Server, Fleet, Beats).

**Rationale:**
- 8.13.x is a recent stable release with mature OTLP support in APM Server
- Consistent versioning prevents compatibility issues between stack components
- 8.13 supports Fleet-managed Elastic Agents with all required integrations
- APM Server 8.x natively accepts OTLP data without needing an intermediate exporter
