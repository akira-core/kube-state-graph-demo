// Package otelinit wires the OTLP trace exporter used by the demo workloads.
//
// The whole point of the demo app is to feed the collector's servicegraph
// connector, which pairs a CLIENT span with the SERVER span it caused and
// stamps `client_<dim>` / `server_<dim>` labels from each side's attributes.
// kube-state-graph then joins those `client_k8s_pod_uid` / `server_k8s_pod_uid`
// labels against its own pod-UID index, so the pod UID MUST reach the span
// resource — it is supplied through OTEL_RESOURCE_ATTRIBUTES (downward API) and
// picked up by resource.WithFromEnv below. Drop that and every call edge in the
// graph degrades to an `external` node.
package otelinit

import (
	"context"
	"fmt"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// Init installs a global tracer provider exporting over OTLP/gRPC and returns
// its shutdown func. Endpoint and resource attributes come from the standard
// OTEL_* environment variables.
func Init(ctx context.Context, serviceName string) (func(context.Context) error, error) {
	res, err := resource.New(ctx,
		resource.WithFromEnv(),
		resource.WithTelemetrySDK(),
		resource.WithAttributes(defaultServiceName(serviceName)...),
	)
	if err != nil {
		return nil, fmt.Errorf("resource: %w", err)
	}

	exp, err := otlptracegrpc.New(ctx, otlptracegrpc.WithInsecure())
	if err != nil {
		return nil, fmt.Errorf("otlp exporter: %w", err)
	}

	tp := sdktrace.NewTracerProvider(
		// AlwaysSample: the servicegraph connector can only pair spans it sees,
		// and a sampled-away server span silently costs an edge.
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
		sdktrace.WithBatcher(exp, sdktrace.WithBatchTimeout(2*time.Second)),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))
	return tp.Shutdown, nil
}
