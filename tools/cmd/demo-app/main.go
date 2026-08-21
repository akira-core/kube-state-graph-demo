// Command demo-app is the single synthetic workload behind every box in the
// demo topology. One image plays every role — edge gateway, mid-tier service,
// storage-backed leaf, load generator — because the graph is built from
// kube-state-metrics and OTLP traces, not from what the process actually does.
//
// It exists to produce two things kube-state-graph cannot synthesise:
//
//	CLIENT/SERVER span pairs carrying k8s.pod.uid  -> pod-calls-pod edges + RED
//	real bytes on a mounted PVC                    -> a moving claim usage figure
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/akira-core/kube-state-graph-demo/tools/internal/otelinit"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "fatal: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	shutdownTracing, err := otelinit.Init(ctx, cfg.AppName)
	if err != nil {
		// Non-fatal: a demo pod that cannot reach the collector should still
		// appear in the topology half of the graph rather than crash-loop.
		slog.Warn("tracing disabled", "err", err)
		shutdownTracing = func(context.Context) error { return nil }
	}

	slog.Info("starting demo-app",
		"app", cfg.AppName,
		"listen_addr", cfg.ListenAddr,
		"upstreams", cfg.Upstreams,
		"db_endpoints", cfg.DBEndpoints,
		"error_rate", cfg.ErrorRate,
		"call_interval", cfg.CallInterval,
		"data_dir", cfg.DataDir,
	)

	call := newCaller(cfg)
	if cfg.CallInterval > 0 {
		go call.loop(ctx, cfg.CallInterval, cfg.AppName)
	}
	if cfg.DataDir != "" {
		go runFiller(ctx, cfg.DataDir, cfg.DataTargetMB)
	}

	srvErr := make(chan error, 1)
	var srv *http.Server
	if cfg.ListenAddr != "" {
		srv = newServer(cfg, call)
		go func() {
			if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
				srvErr <- err
			}
		}()
	}

	select {
	case <-ctx.Done():
	case err := <-srvErr:
		return fmt.Errorf("http server: %w", err)
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var errs []error
	if srv != nil {
		if err := srv.Shutdown(shutdownCtx); err != nil {
			errs = append(errs, fmt.Errorf("shutdown: %w", err))
		}
	}
	// Flush buffered spans last: an unflushed batch is a silently missing edge.
	if err := shutdownTracing(shutdownCtx); err != nil {
		errs = append(errs, fmt.Errorf("tracing shutdown: %w", err))
	}
	return errors.Join(errs...)
}
