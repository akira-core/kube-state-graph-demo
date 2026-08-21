package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	semconv "go.opentelemetry.io/otel/semconv/v1.27.0"
	"go.opentelemetry.io/otel/trace"
)

// dbLatency is the think time of a simulated database hop. Fixed rather than
// configurable: these spans exist to produce a graph edge, not to be measured —
// a virtual-node edge carries no RED metrics in the panel either way.
const dbLatency = 12 * time.Millisecond

// caller performs the outbound half of a demo hop. otelhttp.NewTransport emits
// the CLIENT span the servicegraph connector pairs with the callee's SERVER
// span, and injects traceparent so the pairing has a shared trace id.
type caller struct {
	upstreams   []string
	dbEndpoints []string
	client      *http.Client
	tracer      trace.Tracer
}

func newCaller(cfg config) *caller {
	return &caller{
		upstreams:   cfg.Upstreams,
		dbEndpoints: cfg.DBEndpoints,
		client: &http.Client{
			Transport: otelhttp.NewTransport(http.DefaultTransport),
			Timeout:   10 * time.Second,
		},
		tracer: otel.Tracer("demo-app"),
	}
}

// fanOut calls every upstream in order on the caller's context. A failing
// upstream aborts the fan-out: the demo wants the failure to propagate so the
// error shows up on the whole chain, not just the failing leg.
func (c *caller) fanOut(ctx context.Context) error {
	for _, u := range c.upstreams {
		if err := c.call(ctx, u); err != nil {
			return err
		}
	}
	c.dbCalls(ctx)
	return nil
}

// dbCalls emits one CLIENT span per configured connection string and makes no
// request at all. That absence is the point: with no server span to pair with,
// the collector's servicegraph connector expires the client span and emits a
// VIRTUAL node edge whose `server` label is the connection string itself.
//
// kube-state-graph treats any label containing "://" specially (design D29): it
// parses the host, classifies it as a Kubernetes .svc DNS name, and resolves it
// to a real SERVICE node — which in turn fans out service-selects-pod edges to
// the pods behind it. It is the only path in the graph that produces service
// nodes, so without this the demo would never show one.
//
// The attribute key must be one of the collector's virtual_node_peer_attributes
// and must NOT be one the HTTP instrumentation also sets, or a genuinely lost
// client/server pair would masquerade as a database hop.
func (c *caller) dbCalls(ctx context.Context) {
	for _, ep := range c.dbEndpoints {
		_, span := c.tracer.Start(ctx, "db query",
			trace.WithSpanKind(trace.SpanKindClient),
			trace.WithAttributes(semconv.PeerService(ep)),
		)
		think(ctx, dbLatency)
		span.End()
	}
}

func (c *caller) call(ctx context.Context, url string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return fmt.Errorf("build request %s: %w", url, err)
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return fmt.Errorf("call %s: %w", url, err)
	}
	defer func() { _ = resp.Body.Close() }()
	// Drain so the connection is reusable; the body itself is uninteresting.
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode >= http.StatusInternalServerError {
		return fmt.Errorf("call %s: status %d", url, resp.StatusCode)
	}
	return nil
}

// loop drives traffic from a workload that has no inbound caller of its own
// (the load generator). Each tick opens its own root span so every request is
// a complete trace.
func (c *caller) loop(ctx context.Context, interval time.Duration, appName string) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			tickCtx, span := c.tracer.Start(ctx, appName+" tick", trace.WithSpanKind(trace.SpanKindInternal))
			if err := c.fanOut(tickCtx); err != nil {
				slog.Debug("load generator leg failed", "err", err)
			}
			span.End()
		}
	}
}
