# =============================================================================
# ARCHITECTURAL DECISIONS
# =============================================================================
# Documents the WHY behind every major technical choice.
# Each decision follows the format: Context → Decision → Consequences
# =============================================================================

## Decision 1: AKS with Calico CNI

**Context:** Need a Kubernetes cluster for the assessment that supports network
policies and network flow logging.

**Decision:** Use Azure Kubernetes Service (AKS) with Azure CNI and Calico
network policy provider.

**Consequences:**
- ✅ Calico supports network policy flow logs (required for Section 3.3)
- ✅ AKS is a managed service — Azure handles control plane operations
- ✅ Azure CNI gives each pod a real IP (simpler networking than kubenet)
- ⚠️ Calico adds overhead vs simpler CNI plugins
- ⚠️ 2-node cluster is not HA (acceptable for assessment)

---

## Decision 2: Gateway + Agent OTel Collector Topology

**Context:** Need to collect telemetry from all microservices and deliver it
to Elastic APM Server with intelligent sampling.

**Decision:** Deploy TWO OTel Collector layers:
1. Agent (DaemonSet) — one per node, receives from local pods
2. Gateway (Deployment) — central, performs tail-based sampling

**Consequences:**
- ✅ Low-latency collection (Agent is on the same node as pods)
- ✅ Node-level metrics (Agent collects hostmetrics from its node)
- ✅ Kubernetes enrichment (Agent adds pod names, labels via K8s API)
- ✅ Central sampling (Gateway sees complete traces)
- ✅ Standard pattern recommended by OpenTelemetry project
- ⚠️ Two components to manage instead of one

---

## Decision 3: Tail-Based Sampling Policy (100% / 100% / 10%)

**Context:** Storing ALL traces would overwhelm Elasticsearch. Need to
reduce volume while keeping important traces.

**Decision:** Tail-based sampling on the Gateway with three policies:
1. 100% of error traces (status_code = ERROR)
2. 100% of slow traces (latency > 1 second)
3. 10% of healthy traces (probabilistic baseline)

**Consequences:**
- ✅ Never lose an error trace — essential for debugging
- ✅ Never lose a slow trace — essential for performance analysis
- ✅ 80-85% storage reduction (keep 15-20% of all traces)
- ✅ Statistical baseline maintained for normal traffic
- ⚠️ Tail-based requires Gateway to buffer traces in memory (decision_wait=10s)
- ⚠️ Gateway is a single point of failure (single replica)

**Why NOT head-based sampling:**
Head-based sampling decides at trace START whether to keep it. But you don't
know if a trace will ERROR until it completes. Tail-based waits for COMPLETION.

---

## Decision 4: Three Languages (Go, C#, Node.js)

**Context:** Assessment requires instrumenting multiple services in different
languages to demonstrate OTel cross-language support.

**Decision:** Instrument:
1. frontend (Go) — serves web UI, makes gRPC calls
2. cartservice (C#/.NET) — manages cart, uses Redis
3. paymentservice (Node.js) — processes payments

**Consequences:**
- ✅ Covers 3 language ecosystems
- ✅ Natural checkout flow: frontend → cart → checkout → payment
- ✅ Each has a different OTel SDK (Go, .NET, Node.js)
- ✅ Demonstrates environment-variable-based configuration

---

## Decision 5: Elastic APM RUM Agent for Browser Monitoring

**Context:** Need Real User Monitoring to capture browser-side performance.

**Decision:** Use Elastic APM RUM Agent (JavaScript library loaded in browser).

**Consequences:**
- ✅ Native Kibana integration — User Experience dashboard auto-populates
- ✅ Automatic Core Web Vitals capture (LCP, FID, CLS, TTFB)
- ✅ Distributed tracing: browser spans connect to backend traces
- ✅ No additional server infrastructure needed
- ⚠️ Requires APM Server to be browser-accessible (via Ingress)
- ⚠️ Requires modifying frontend HTML (adding script tag)

---

## Decision 6: Fleet-Managed Elastic Agent

**Context:** Need to collect infrastructure metrics from PostgreSQL, Redis,
NGINX, and system-level resources.

**Decision:** Use Elastic Agent managed by Fleet Server for all infrastructure
monitoring integrations.

**Consequences:**
- ✅ Centralized configuration management (Fleet Server)
- ✅ Pre-built dashboards for each integration
- ✅ Unified agent (one binary collects all metric types)
- ⚠️ Fleet Server adds another component to manage
- ⚠️ More complex than standalone Metricbeat

---

## Decision 7: GitHub Actions for CI/CD

**Context:** Previous implementation used manual shell scripts run locally.
This was fragile and hard to reproduce.

**Decision:** Use GitHub Actions workflows for all deployments:
1. Infrastructure (AKS creation)
2. Observability (Elastic Stack + OTel)
3. Application (Online Boutique + monitoring)

**Consequences:**
- ✅ Reproducible — anyone can re-run the same deployment
- ✅ Auditable — every deployment is a workflow run with logs
- ✅ No local tool dependencies beyond git
- ✅ Manual trigger (workflow_dispatch) — you control when things happen
- ⚠️ Requires AZURE_CREDENTIALS secret in GitHub repo settings
- ⚠️ Longer feedback loop than local scripts (runs in cloud)

---

## Decision 8: Vendored Application Manifests

**Context:** Online Boutique manifests are hosted on Google's GitHub repo.
Previous implementation applied them directly from URL.

**Decision:** Copy (vendor) the manifests into our repository.

**Consequences:**
- ✅ Deployment doesn't depend on Google's servers
- ✅ We can review and audit exactly what's deployed
- ✅ Git history shows changes to the application config
- ✅ Can customize manifests (namespaces, resource limits)
- ⚠️ Must manually update when upstream changes

---

## Decision 9: PostgreSQL StatefulSet (Not Part of Online Boutique)

**Context:** Assessment Section 3.2 requires database monitoring. Online
Boutique doesn't include a SQL database.

**Decision:** Deploy PostgreSQL as a StatefulSet with monitoring-friendly
configuration (pg_stat_statements, slow query logging).

**Consequences:**
- ✅ Satisfies database monitoring requirement
- ✅ pg_stat_statements enables query performance tracking
- ✅ log_min_duration_statement=200ms captures slow queries
- ✅ max_connections=100 gives meaningful alert threshold (80%)
- ⚠️ Not connected to the application (standalone for monitoring)

---

## Decision 10: Elastic Stack Version 8.13.4 Across All Components

**Context:** ECK manages Elasticsearch, Kibana, APM Server, and Fleet Server.
Version mismatches between components cause compatibility issues.

**Decision:** Pin ALL Elastic components to version 8.13.4.

**Consequences:**
- ✅ Known stable OTLP support in APM Server 8.13.4
- ✅ No version compatibility issues between components
- ✅ Filebeat 8.13.4 matches Elasticsearch 8.13.4
- ⚠️ Not the latest version (8.15+ exists) — acceptable for assessment
