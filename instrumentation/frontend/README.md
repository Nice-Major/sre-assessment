# =============================================================================
# frontend (Go) — Go module dependencies for OTel instrumentation
# Add these to the existing go.mod via: go get <package>
# =============================================================================
#
# Run inside the frontend service directory:
#
#   go get go.opentelemetry.io/otel@v1.24.0
#   go get go.opentelemetry.io/otel/sdk@v1.24.0
#   go get go.opentelemetry.io/otel/sdk/metric@v1.24.0
#   go get go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc@v1.24.0
#   go get go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc@v1.24.0
#   go get go.opentelemetry.io/otel/propagation@v1.24.0
#   go get go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp@v0.49.0
#   go get go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc@v0.49.0
#
# =============================================================================
# Dockerfile patch — add to the existing frontend Dockerfile build stage:
#
#   ENV OTEL_EXPORTER_OTLP_ENDPOINT=otel-agent-opentelemetry-collector.otel-system.svc.cluster.local:4317
#
# Kubernetes deployment patch — add these env vars to the frontend container:
#
#   env:
#     - name: OTEL_EXPORTER_OTLP_ENDPOINT
#       value: "otel-agent-opentelemetry-collector.otel-system.svc.cluster.local:4317"
#     - name: OTEL_SERVICE_NAME
#       value: "frontend"
#     - name: OTEL_RESOURCE_ATTRIBUTES
#       value: "service.version=1.0.0,deployment.environment=assessment"
