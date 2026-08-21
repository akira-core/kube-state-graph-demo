package main

import (
	"context"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

// newServer builds the inbound HTTP surface. Only "/" is traced: probes must
// not become graph edges, and an untraced /healthz keeps the servicegraph
// connector's edge set equal to the real call topology.
func newServer(cfg config, caller *caller) *http.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.Handle("/", otelhttp.NewHandler(handleWork(cfg, caller), "work"))

	return &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
}

// handleWork answers an inbound request the way a real service would: think for
// a bit, fan out to every configured upstream on the SAME trace context, then
// fail a configured fraction of the time so the panel has a non-zero
// `errorRate` to render (as distinct from an absent one).
func handleWork(cfg config, caller *caller) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		think(r.Context(), cfg.Latency)

		if err := caller.fanOut(r.Context()); err != nil {
			slog.Debug("upstream call failed", "app", cfg.AppName, "err", err)
			http.Error(w, "upstream failure", http.StatusBadGateway)
			return
		}
		if rand.Float64() < cfg.ErrorRate {
			http.Error(w, "synthetic failure", http.StatusInternalServerError)
			return
		}
		fmt.Fprintf(w, "%s ok\n", cfg.AppName)
	})
}

// think sleeps for a jittered multiple of base so the latency histogram spans
// several buckets — a single fixed value collapses p90 onto one boundary.
func think(ctx context.Context, base time.Duration) {
	if base <= 0 {
		return
	}
	d := time.Duration(float64(base) * (0.5 + rand.Float64()*1.5))
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}
