// =============================================================================
// frontend (Go) — OpenTelemetry Instrumentation
// This file is added to the frontend service to initialize the OTel SDK
// with auto + custom instrumentation.
//
// Integration steps:
//   1. Copy this file into the frontend service source directory
//   2. Call InitTracer() at the top of main()
//   3. Wrap HTTP handlers with otelhttp middleware
//   4. Add gRPC interceptors to all gRPC client connections
//   5. Rebuild the Docker image
// =============================================================================

package main

import (
	"context"
	"log"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.24.0"
)

const (
	serviceName    = "frontend"
	serviceVersion = "1.0.0"
	environment    = "assessment"
)

var (
	tracer          = otel.Tracer(serviceName)
	meter           = otel.Meter(serviceName)
	httpRequestsBy  metric.Int64Counter   // custom metric: requests by route
	pageRenderDur   metric.Float64Histogram // custom metric: page render duration
)

// InitTracer initializes the OpenTelemetry SDK for the frontend service.
// Returns a cleanup function that flushes and shuts down providers.
func InitTracer() func() {
	ctx := context.Background()

	// Build shared resource
	res, err := resource.Merge(
		resource.Default(),
		resource.NewWithAttributes(
			semconv.SchemaURL,
			semconv.ServiceName(serviceName),
			semconv.ServiceVersion(serviceVersion),
			semconv.DeploymentEnvironment(environment),
		),
	)
	if err != nil {
		log.Fatalf("failed to create resource: %v", err)
	}

	// ── Trace exporter ──
	collectorEndpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if collectorEndpoint == "" {
		collectorEndpoint = "otel-agent-opentelemetry-collector.otel-system.svc.cluster.local:4317"
	}

	traceExporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(collectorEndpoint),
		otlptracegrpc.WithInsecure(),
	)
	if err != nil {
		log.Fatalf("failed to create trace exporter: %v", err)
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExporter, sdktrace.WithBatchTimeout(5*time.Second)),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)

	// ── Propagator (W3C TraceContext + Baggage) ──
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	// ── Metrics exporter ──
	metricExporter, err := otlpmetricgrpc.New(ctx,
		otlpmetricgrpc.WithEndpoint(collectorEndpoint),
		otlpmetricgrpc.WithInsecure(),
	)
	if err != nil {
		log.Fatalf("failed to create metric exporter: %v", err)
	}

	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExporter, sdkmetric.WithInterval(15*time.Second))),
	)
	otel.SetMeterProvider(mp)

	// ── Register custom metrics ──
	httpRequestsBy, _ = meter.Int64Counter("frontend.http_requests_by_route",
		metric.WithDescription("HTTP requests by route and status"),
		metric.WithUnit("{request}"),
	)
	pageRenderDur, _ = meter.Float64Histogram("frontend.page_render_duration",
		metric.WithDescription("Page template render duration"),
		metric.WithUnit("ms"),
	)

	return func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = tp.Shutdown(ctx)
		_ = mp.Shutdown(ctx)
	}
}

// ---------- Custom Span Helpers ----------

// TraceRenderProductPage creates a custom span around product page rendering.
// Custom span 1 of 2 required by the assessment.
func TraceRenderProductPage(ctx context.Context, productID string, productCount int) (context.Context, func()) {
	ctx, span := tracer.Start(ctx, "render-product-page")
	span.SetAttributes(
		attribute.String("product.id", productID),
		attribute.Int("product.count", productCount),
		attribute.String("page.route", "/product/"+productID),
	)
	return ctx, func() { span.End() }
}

// TraceGRPCProductCatalogCall creates a custom span around the gRPC call
// to the product catalog service.
// Custom span 2 of 2 required by the assessment.
func TraceGRPCProductCatalogCall(ctx context.Context, method string) (context.Context, func()) {
	ctx, span := tracer.Start(ctx, "grpc-call-productcatalog")
	span.SetAttributes(
		attribute.String("rpc.method", method),
		attribute.String("rpc.service", "productcatalogservice"),
	)
	return ctx, func() { span.End() }
}

// RecordHTTPRequest records a custom metric for HTTP requests by route.
func RecordHTTPRequest(ctx context.Context, route string, statusCode int) {
	httpRequestsBy.Add(ctx, 1,
		metric.WithAttributes(
			attribute.String("http.route", route),
			attribute.Int("http.status_code", statusCode),
		),
	)
}

// RecordPageRenderDuration records page render time as a histogram.
func RecordPageRenderDuration(ctx context.Context, route string, durationMs float64) {
	pageRenderDur.Record(ctx, durationMs,
		metric.WithAttributes(
			attribute.String("page.route", route),
		),
	)
}
