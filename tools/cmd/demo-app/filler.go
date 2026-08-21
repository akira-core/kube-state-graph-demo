package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"math/rand/v2"
	"os"
	"path/filepath"
	"time"
)

const (
	fillerFileName = "demo-data.bin"
	fillerTick     = 30 * time.Second
	mib            = 1 << 20
	chunkBytes     = 4 * mib
)

// runFiller keeps a file on the mounted PVC oscillating in size so the claim
// reports a moving used-bytes figure. Growth is written for real (never a
// sparse truncate) because kubelet's volume stats measure allocated blocks —
// a sparse file would report a used size the demo never actually consumed.
func runFiller(ctx context.Context, dir string, targetMB int) {
	path := filepath.Join(dir, fillerFileName)
	ticker := time.NewTicker(fillerTick)
	defer ticker.Stop()

	for {
		want := int64(float64(targetMB) * (0.25 + rand.Float64()*0.6) * mib)
		if err := resize(path, want); err != nil {
			slog.Warn("pvc filler failed", "path", path, "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func resize(path string, want int64) error {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return fmt.Errorf("open: %w", err)
	}
	defer func() { _ = f.Close() }()

	info, err := f.Stat()
	if err != nil {
		return fmt.Errorf("stat: %w", err)
	}
	if want <= info.Size() {
		if err := f.Truncate(want); err != nil {
			return fmt.Errorf("truncate: %w", err)
		}
		return f.Sync()
	}

	if _, err := f.Seek(0, io.SeekEnd); err != nil {
		return fmt.Errorf("seek: %w", err)
	}
	buf := make([]byte, chunkBytes)
	for remaining := want - info.Size(); remaining > 0; {
		n := int64(len(buf))
		if remaining < n {
			n = remaining
		}
		if _, err := f.Write(buf[:n]); err != nil {
			return fmt.Errorf("write: %w", err)
		}
		remaining -= n
	}
	return f.Sync()
}
