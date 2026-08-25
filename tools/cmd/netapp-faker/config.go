package main

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"time"
)

// config drives the fake ONTAP estate. Everything except the endpoints has a
// working default so the chart only has to wire the two VictoriaMetrics URLs.
type config struct {
	SelectURL    string        // read endpoint's Prometheus API base, e.g. http://vmselect:8481/select/0/prometheus
	SelectUser   string        // basic-auth user for SelectURL; empty means unauthenticated
	SelectPass   string        // basic-auth password for SelectURL
	InsertURL    string        // vminsert Prometheus API base, e.g. http://vminsert:8480/insert/0/prometheus
	StorageClass string        // only claims on this StorageClass get a fake backend
	OntapCluster string        // ONTAP cluster name — NOT a Kubernetes cluster
	SVM          string        // the storage virtual machine every fake volume lives in
	Interval     time.Duration // push cadence
	Lookback     time.Duration // discovery window against vmselect
	ExtraLabels  map[string]string
}

func loadConfig() (config, error) {
	cfg := config{
		SelectURL:    strings.TrimRight(os.Getenv("VM_SELECT_URL"), "/"),
		SelectUser:   os.Getenv("VM_SELECT_USERNAME"),
		SelectPass:   os.Getenv("VM_SELECT_PASSWORD"),
		InsertURL:    strings.TrimRight(os.Getenv("VM_INSERT_URL"), "/"),
		StorageClass: envStr("STORAGE_CLASS", "netapp-nas"),
		OntapCluster: envStr("ONTAP_CLUSTER", "ontap-lab"),
		SVM:          envStr("ONTAP_SVM", "svm_demo"),
		Interval:     15 * time.Second,
		Lookback:     10 * time.Minute,
	}
	if cfg.SelectURL == "" || cfg.InsertURL == "" {
		return cfg, fmt.Errorf("VM_SELECT_URL and VM_INSERT_URL are both required")
	}
	// Half a pair is a typo, not a configuration. Accepting it would send
	// unauthenticated reads at an endpoint that answers 401, and the faker would
	// report a discovery failure that names the wrong cause.
	if (cfg.SelectUser == "") != (cfg.SelectPass == "") {
		return cfg, fmt.Errorf("VM_SELECT_USERNAME and VM_SELECT_PASSWORD must be set together or not at all")
	}

	var err error
	if cfg.Interval, err = envDur("INTERVAL", cfg.Interval); err != nil {
		return cfg, err
	}
	if cfg.Lookback, err = envDur("LOOKBACK", cfg.Lookback); err != nil {
		return cfg, err
	}
	if cfg.ExtraLabels, err = parseLabels(os.Getenv("EXTRA_LABELS")); err != nil {
		return cfg, err
	}
	return cfg, nil
}

// parseLabels reads the `k=v,k=v` form used for the az / env external labels.
// kube-state-graph pushes those as raw PromQL matchers against EVERY topology
// family including this one, so a Harvest series missing them drops out of any
// filtered request — silently, as an empty storage half rather than an error.
func parseLabels(raw string) (map[string]string, error) {
	out := map[string]string{}
	for _, pair := range strings.Split(raw, ",") {
		if pair = strings.TrimSpace(pair); pair == "" {
			continue
		}
		k, v, ok := strings.Cut(pair, "=")
		if !ok || strings.TrimSpace(k) == "" {
			return nil, fmt.Errorf("invalid EXTRA_LABELS entry %q: want key=value", pair)
		}
		out[strings.TrimSpace(k)] = strings.TrimSpace(v)
	}
	return out, nil
}

// sortedKeys keeps rendered label sets deterministic — the exposition text is
// diffed by eye during demos, and stable ordering makes that possible.
func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func envStr(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func envDur(key string, def time.Duration) (time.Duration, error) {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return def, fmt.Errorf("invalid %s=%q (want a Go duration like 15s): %w", key, v, err)
	}
	return d, nil
}
