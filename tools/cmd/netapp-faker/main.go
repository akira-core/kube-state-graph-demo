// Command netapp-faker synthesises the NetApp ONTAP half of the demo graph.
//
// Everything else in this demo is real: real pods, real claims, real
// kube-state-metrics, real traces. The storage array is the one component a
// laptop cannot run, so this process stands in for NetApp Harvest — it emits
// the same Harvest series kube-state-graph reads, against the PV names the kind
// cluster actually assigned.
//
// It DISCOVERS rather than fixtures: each tick it asks VictoriaMetrics which
// claims exist on the demo StorageClass, and renders a storage chain for each.
// Create a PVC and its aggregate, controller and I/O appear within one tick.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
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
	slog.Info("starting netapp-faker",
		"select_url", cfg.SelectURL,
		"insert_url", cfg.InsertURL,
		"storage_class", cfg.StorageClass,
		"ontap_cluster", cfg.OntapCluster,
		"svm", cfg.SVM,
		"interval", cfg.Interval,
		"emit_volume_stats", cfg.VolumeStats,
		"extra_labels", cfg.ExtraLabels,
	)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	client := &http.Client{Timeout: 15 * time.Second}
	ticker := time.NewTicker(cfg.Interval)
	defer ticker.Stop()

	for {
		tick(ctx, client, cfg)
		select {
		case <-ctx.Done():
			slog.Info("shutdown signal received")
			return nil
		case <-ticker.C:
		}
	}
}

// tick is failure-tolerant on purpose: VictoriaMetrics comes up alongside this
// process and the first few discoveries will fail. A crash-loop would only
// obscure that, so every leg logs and waits for the next tick.
func tick(ctx context.Context, client *http.Client, cfg config) {
	claims, err := discover(ctx, client, cfg)
	if err != nil {
		slog.Warn("discovery failed", "err", err)
		return
	}
	if len(claims) == 0 {
		// Not an error at startup — kube-state-metrics may not have been
		// scraped yet, or nothing has claimed the demo StorageClass.
		slog.Info("no claims on the demo storage class yet", "storage_class", cfg.StorageClass)
	}

	body := render(cfg, claims, time.Now())
	if err := push(ctx, client, cfg, body); err != nil {
		slog.Warn("push failed", "err", err)
		return
	}
	slog.Info("pushed fake ontap estate", "claims", len(claims), "aggregates", len(estate))
}
