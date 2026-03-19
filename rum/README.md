# RUM Integration Guide

## Overview
This directory contains the Elastic APM RUM (Real User Monitoring) agent integration
for the Online Boutique frontend.

## Files
- `rum-init.html` — The `<script>` block to inject into the frontend HTML templates

## How to Integrate

### 1. Locate the frontend templates
The Online Boutique frontend is a Go server that renders HTML templates.
Templates are typically in: `src/frontend/templates/`

### 2. Find the base layout
Look for the common header/layout template (e.g., `header.html`, `_layout.html`).

### 3. Inject the RUM script
Copy the contents of `rum-init.html` into the `<head>` section of the layout template,
before the closing `</head>` tag.

### 4. Update the APM Server URL
The `APM_SERVER_URL` variable in the script must point to a browser-accessible
APM Server endpoint:

- **Via Ingress (recommended):** `http://apm.<INGRESS_IP>.nip.io`
- **Fallback (local dev):** `http://localhost:8200` (with port-forward)

### 5. Verify CORS configuration
The APM Server must accept RUM data from the frontend origin.
This is configured in `kubernetes/elastic-stack/apm-server.yaml`:
```yaml
rum:
  enabled: true
  allow_origins: ["*"]
```

### 6. Verify in Kibana
After loading pages in the browser:
1. Go to Kibana → Observability → User Experience
2. Verify Core Web Vitals appear (LCP, FID, CLS, TTFB)
3. Go to Kibana → Observability → APM → Traces
4. Find a trace that starts with a browser span and flows through backend services

## What's Captured
- Page load performance (document load transaction)
- Fetch/XHR requests with distributed tracing headers
- User interaction events (Add to Cart, Checkout clicks)
- Core Web Vitals: LCP, FID, CLS, TTFB
- Custom labels: page.route, session.id, device.type
