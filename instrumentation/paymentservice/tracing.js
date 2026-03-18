// =============================================================================
// paymentservice (Node.js) — OpenTelemetry Instrumentation
//
// This file MUST be loaded BEFORE any other application code.
// Add to the Dockerfile CMD or node start command:
//   node --require ./tracing.js server.js
//
// Or set the environment variable:
//   NODE_OPTIONS="--require ./tracing.js"
//
// npm packages required:
//   npm install @opentelemetry/sdk-node \
//     @opentelemetry/auto-instrumentations-node \
//     @opentelemetry/exporter-trace-otlp-grpc \
//     @opentelemetry/exporter-metrics-otlp-grpc \
//     @opentelemetry/sdk-metrics \
//     @opentelemetry/resources \
//     @opentelemetry/semantic-conventions \
//     @opentelemetry/api
// =============================================================================

'use strict';

const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-grpc');
const { OTLPMetricExporter } = require('@opentelemetry/exporter-metrics-otlp-grpc');
const { PeriodicExportingMetricReader } = require('@opentelemetry/sdk-metrics');
const { Resource } = require('@opentelemetry/resources');
const {
  SEMRESATTRS_SERVICE_NAME,
  SEMRESATTRS_SERVICE_VERSION,
  SEMRESATTRS_DEPLOYMENT_ENVIRONMENT,
} = require('@opentelemetry/semantic-conventions');

const COLLECTOR_ENDPOINT =
  process.env.OTEL_EXPORTER_OTLP_ENDPOINT ||
  'grpc://otel-agent-opentelemetry-collector.otel-system.svc.cluster.local:4317';

const sdk = new NodeSDK({
  resource: new Resource({
    [SEMRESATTRS_SERVICE_NAME]: 'paymentservice',
    [SEMRESATTRS_SERVICE_VERSION]: '1.0.0',
    [SEMRESATTRS_DEPLOYMENT_ENVIRONMENT]: 'assessment',
  }),
  traceExporter: new OTLPTraceExporter({
    url: COLLECTOR_ENDPOINT,
  }),
  metricReader: new PeriodicExportingMetricReader({
    exporter: new OTLPMetricExporter({
      url: COLLECTOR_ENDPOINT,
    }),
    exportIntervalMillis: 15000,
  }),
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-fs': { enabled: false },
    }),
  ],
});

sdk.start();
console.log('[OTel] paymentservice tracing initialized');

process.on('SIGTERM', () => {
  sdk.shutdown().then(() => process.exit(0));
});
