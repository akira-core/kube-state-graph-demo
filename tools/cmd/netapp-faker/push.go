package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// push writes one tick of exposition text to VictoriaMetrics.
//
// /api/v1/import/prometheus stamps every sample at ingestion time when no
// explicit timestamp is given, so a steady loop is the whole mechanism: each
// tick lands a fresh sample inside whatever [start, end] window the panel asks
// for, and last_over_time picks it up.
func push(ctx context.Context, client *http.Client, cfg config, body string) error {
	if strings.TrimSpace(body) == "" {
		return nil
	}
	endpoint := cfg.InsertURL + "/api/v1/import/prometheus"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(body))
	if err != nil {
		return fmt.Errorf("build import request: %w", err)
	}
	req.Header.Set("Content-Type", "text/plain")

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("import to %s: %w", endpoint, err)
	}
	defer func() { _ = resp.Body.Close() }()
	payload, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
	if resp.StatusCode >= http.StatusMultipleChoices {
		return fmt.Errorf("import to %s: status %d: %s", endpoint, resp.StatusCode, truncate(string(payload), 200))
	}
	return nil
}
