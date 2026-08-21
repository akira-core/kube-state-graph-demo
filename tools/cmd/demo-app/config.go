package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// config is the whole knob surface of the demo workload. Every field has an
// environment default so one image can play every role in the demo topology
// (edge gateway, mid-tier service, storage-backed leaf, load generator).
type config struct {
	AppName      string        // service.name / graph node label
	ListenAddr   string        // "" disables the HTTP server (pure load generator)
	Upstreams    []string      // called in order on every inbound request
	ErrorRate    float64       // fraction of inbound requests answered 500
	Latency      time.Duration // base server-side think time
	CallInterval time.Duration // >0 turns on the outbound caller loop
	DBEndpoints  []string      // connection strings emitted as virtual-node client spans
	DataDir      string        // "" disables the PVC filler
	DataTargetMB int           // size the filler grows its file to
}

func loadConfig() (config, error) {
	host, _ := os.Hostname()
	cfg := config{
		AppName:      envStr("APP_NAME", host),
		ListenAddr:   envStr("LISTEN_ADDR", ":8080"),
		Upstreams:    splitList(envStr("UPSTREAMS", "")),
		DBEndpoints:  splitList(envStr("DB_ENDPOINTS", "")),
		Latency:      50 * time.Millisecond,
		DataDir:      envStr("DATA_DIR", ""),
		DataTargetMB: 64,
	}

	var err error
	if cfg.ErrorRate, err = envFloat("ERROR_RATE", 0); err != nil {
		return cfg, err
	}
	if cfg.ErrorRate < 0 || cfg.ErrorRate > 1 {
		return cfg, fmt.Errorf("ERROR_RATE must be within [0,1], got %v", cfg.ErrorRate)
	}
	if cfg.Latency, err = envDur("LATENCY", cfg.Latency); err != nil {
		return cfg, err
	}
	if cfg.CallInterval, err = envDur("CALL_INTERVAL", 0); err != nil {
		return cfg, err
	}
	if cfg.DataTargetMB, err = envInt("DATA_TARGET_MB", cfg.DataTargetMB); err != nil {
		return cfg, err
	}
	if cfg.ListenAddr == "" && cfg.CallInterval == 0 {
		return cfg, fmt.Errorf("nothing to do: set LISTEN_ADDR, CALL_INTERVAL, or both")
	}
	return cfg, nil
}

func envStr(key, def string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return def
}

func envFloat(key string, def float64) (float64, error) {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def, nil
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return def, fmt.Errorf("invalid %s=%q: %w", key, v, err)
	}
	return f, nil
}

func envInt(key string, def int) (int, error) {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def, fmt.Errorf("invalid %s=%q: %w", key, v, err)
	}
	return n, nil
}

func envDur(key string, def time.Duration) (time.Duration, error) {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return def, fmt.Errorf("invalid %s=%q (want a Go duration like 250ms): %w", key, v, err)
	}
	return d, nil
}

func splitList(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
