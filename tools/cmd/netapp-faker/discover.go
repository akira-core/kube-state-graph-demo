package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
)

// claim is one Kubernetes PVC that should appear to have a NetApp backend.
//
// VolumeName is the whole join: kube-state-graph rewrites
// kube_persistentvolumeclaim_info.volumename into a match token and compares it
// against the stock Harvest `volume` label, and nothing else. flexVolName is
// this side of that derivation. A claim still in Pending has no bound PV, hence
// no VolumeName, and is skipped — inventing one would create a storage chain
// that hangs off no claim.
type claim struct {
	Cluster    string
	Namespace  string
	Name       string
	VolumeName string
}

type promResponse struct {
	Status string `json:"status"`
	Error  string `json:"error"`
	Data   struct {
		Result []struct {
			Metric map[string]string `json:"metric"`
			Value  []any             `json:"value"`
		} `json:"result"`
	} `json:"data"`
}

// discover asks vmselect which claims exist, rather than carrying a static
// fixture. That is what makes the fake storage follow the real cluster: create
// a PVC on the demo StorageClass and a NetApp chain appears behind it within
// one tick, with the PV name Kubernetes actually assigned.
func discover(ctx context.Context, client *http.Client, cfg config) ([]claim, error) {
	q := fmt.Sprintf(`last_over_time(kube_persistentvolumeclaim_info{storageclass=%q}[%s])`,
		cfg.StorageClass, promDuration(cfg.Lookback))

	endpoint := cfg.SelectURL + "/api/v1/query?" + url.Values{"query": {q}}.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("build query: %w", err)
	}
	// The read endpoint may sit behind an auth proxy — in the demo it is vmauth
	// in front of the single-node store, which is where the kube-state-metrics
	// families live. Writes go somewhere else entirely and stay unauthenticated.
	if cfg.SelectUser != "" {
		req.SetBasicAuth(cfg.SelectUser, cfg.SelectPass)
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("query vmselect: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, fmt.Errorf("read query response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("query vmselect: status %d: %s", resp.StatusCode, truncate(string(body), 200))
	}

	var parsed promResponse
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, fmt.Errorf("decode query response: %w", err)
	}
	if parsed.Status != "success" {
		return nil, fmt.Errorf("query failed: %s", parsed.Error)
	}

	claims := make([]claim, 0, len(parsed.Data.Result))
	for _, r := range parsed.Data.Result {
		if r.Metric["volumename"] == "" {
			continue
		}
		claims = append(claims, claim{
			Cluster:    r.Metric["cluster"],
			Namespace:  r.Metric["namespace"],
			Name:       r.Metric["persistentvolumeclaim"],
			VolumeName: r.Metric["volumename"],
		})
	}
	// Stable order so the aggregate assignment below, and the rendered output,
	// do not shuffle between ticks.
	sort.Slice(claims, func(i, j int) bool { return claims[i].VolumeName < claims[j].VolumeName })
	return claims, nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
