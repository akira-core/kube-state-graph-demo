package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
)

// claim is one Kubernetes PVC that should appear to have a NetApp backend.
//
// VolumeName is the whole join: kube-state-graph matches
// kube_persistentvolumeclaim_info.volumename against volume_labels.volume_name
// and nothing else. A claim still in Pending has no bound PV, hence no
// VolumeName, and is skipped — inventing one would create a storage chain that
// hangs off no claim.
type claim struct {
	Cluster    string
	Namespace  string
	Name       string
	VolumeName string
	// Requested size, when kube-state-metrics exposes it. Zero means unknown,
	// and the caller falls back to a fixed figure.
	CapacityB float64
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

	// Requested sizes are a best-effort enrichment: a query error here must not
	// cost the whole storage topology, so the miss degrades to a fixed figure.
	capacities, err := discoverCapacities(ctx, client, cfg)
	if err != nil {
		capacities = nil
	}

	claims := make([]claim, 0, len(parsed.Data.Result))
	for _, r := range parsed.Data.Result {
		if r.Metric["volumename"] == "" {
			continue
		}
		c := claim{
			Cluster:    r.Metric["cluster"],
			Namespace:  r.Metric["namespace"],
			Name:       r.Metric["persistentvolumeclaim"],
			VolumeName: r.Metric["volumename"],
		}
		c.CapacityB = capacities[claimKey(c)]
		claims = append(claims, c)
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

// claimKey identifies a claim the way kube-state-graph does: cluster-scoped,
// namespaced, by name.
func claimKey(c claim) string {
	return c.Cluster + "/" + c.Namespace + "/" + c.Name
}

// discoverCapacities reads each claim's requested size so the stand-in volume
// stats report the size the claim actually asked for. Not a series the graph
// reads — it just keeps the demo's numbers self-consistent.
func discoverCapacities(ctx context.Context, client *http.Client, cfg config) (map[string]float64, error) {
	q := fmt.Sprintf(`last_over_time(kube_persistentvolumeclaim_resource_requests_storage_bytes[%s])`,
		promDuration(cfg.Lookback))

	endpoint := cfg.SelectURL + "/api/v1/query?" + url.Values{"query": {q}}.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("build capacity query: %w", err)
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("query capacities: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, fmt.Errorf("read capacity response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("query capacities: status %d: %s", resp.StatusCode, truncate(string(body), 200))
	}

	var parsed promResponse
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, fmt.Errorf("decode capacity response: %w", err)
	}

	out := make(map[string]float64, len(parsed.Data.Result))
	for _, r := range parsed.Data.Result {
		if len(r.Value) != 2 {
			continue
		}
		raw, ok := r.Value[1].(string)
		if !ok {
			continue
		}
		v, err := strconv.ParseFloat(raw, 64)
		if err != nil || v <= 0 {
			continue
		}
		out[r.Metric["cluster"]+"/"+r.Metric["namespace"]+"/"+r.Metric["persistentvolumeclaim"]] = v
	}
	return out, nil
}
