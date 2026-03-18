// =============================================================================
// cartservice (C# .NET) — OpenTelemetry Instrumentation Setup
//
// Integration steps:
//   1. Add NuGet packages (see below)
//   2. Add this initialization code to Program.cs / Startup.cs
//   3. Use CartServiceTracing class for custom spans and metrics
//   4. Rebuild the Docker image
// =============================================================================
//
// NuGet packages to add to cartservice.csproj:
//
//   <PackageReference Include="OpenTelemetry" Version="1.7.0" />
//   <PackageReference Include="OpenTelemetry.Extensions.Hosting" Version="1.7.0" />
//   <PackageReference Include="OpenTelemetry.Instrumentation.AspNetCore" Version="1.7.1" />
//   <PackageReference Include="OpenTelemetry.Instrumentation.GrpcNetClient" Version="1.7.0-beta.1" />
//   <PackageReference Include="OpenTelemetry.Instrumentation.StackExchangeRedis" Version="1.0.0-rc9.14" />
//   <PackageReference Include="OpenTelemetry.Exporter.OpenTelemetryProtocol" Version="1.7.0" />
//

using System.Diagnostics;
using System.Diagnostics.Metrics;
using OpenTelemetry;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

namespace cartservice;

/// <summary>
/// Configures OpenTelemetry for the cartservice.
/// Call ConfigureOpenTelemetry(builder.Services) in Program.cs.
/// </summary>
public static class OtelConfig
{
    private const string ServiceName = "cartservice";
    private const string ServiceVersion = "1.0.0";

    public static void ConfigureOpenTelemetry(IServiceCollection services)
    {
        var collectorEndpoint = Environment.GetEnvironmentVariable("OTEL_EXPORTER_OTLP_ENDPOINT")
            ?? "http://otel-agent-opentelemetry-collector.otel-system.svc.cluster.local:4317";

        services.AddOpenTelemetry()
            .ConfigureResource(resource => resource
                .AddService(
                    serviceName: ServiceName,
                    serviceVersion: ServiceVersion)
                .AddAttributes(new[]
                {
                    new KeyValuePair<string, object>("deployment.environment", "assessment"),
                }))
            .WithTracing(tracing => tracing
                .AddAspNetCoreInstrumentation()
                .AddGrpcClientInstrumentation()
                .AddRedisInstrumentation()
                .AddSource(CartServiceTracing.ActivitySourceName)
                .AddOtlpExporter(options =>
                {
                    options.Endpoint = new Uri(collectorEndpoint);
                }))
            .WithMetrics(metrics => metrics
                .AddAspNetCoreInstrumentation()
                .AddMeter(CartServiceMetrics.MeterName)
                .AddOtlpExporter(options =>
                {
                    options.Endpoint = new Uri(collectorEndpoint);
                }));
    }
}

/// <summary>
/// Custom tracing for cart business operations.
/// Provides 2 custom spans as required by the assessment.
/// </summary>
public static class CartServiceTracing
{
    public const string ActivitySourceName = "CartService.CustomTraces";
    private static readonly ActivitySource ActivitySource = new(ActivitySourceName, "1.0.0");

    /// <summary>
    /// Custom span 1: Validates cart contents before checkout.
    /// </summary>
    public static Activity? StartValidateCartContents(string userId, int itemCount, decimal totalValue)
    {
        var activity = ActivitySource.StartActivity("validate-cart-contents");
        activity?.SetTag("user.id", userId);
        activity?.SetTag("cart.item_count", itemCount);
        activity?.SetTag("cart.total_value", (double)totalValue);
        return activity;
    }

    /// <summary>
    /// Custom span 2: Tracks Redis cart update operations.
    /// </summary>
    public static Activity? StartRedisCartUpdate(string userId, string operation)
    {
        var activity = ActivitySource.StartActivity("redis-cart-update");
        activity?.SetTag("user.id", userId);
        activity?.SetTag("cart.operation", operation); // add, remove, empty
        return activity;
    }
}

/// <summary>
/// Custom metrics for cart operations.
/// Provides the custom counter required by the assessment.
/// </summary>
public static class CartServiceMetrics
{
    public const string MeterName = "CartService.Metrics";
    private static readonly Meter CartMeter = new(MeterName, "1.0.0");

    /// <summary>
    /// Custom metric: cart_operations_total — counter with operation type tag.
    /// Tracks every cart add, remove, and empty operation.
    /// </summary>
    private static readonly Counter<long> CartOperations = CartMeter.CreateCounter<long>(
        "cart_operations_total",
        unit: "{operation}",
        description: "Total cart operations by type");

    public static void RecordCartOperation(string operation, string userId)
    {
        CartOperations.Add(1,
            new KeyValuePair<string, object?>("operation", operation),
            new KeyValuePair<string, object?>("user.id", userId));
    }
}
