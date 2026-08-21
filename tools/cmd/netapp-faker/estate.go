package main

import (
	"fmt"
	"hash/fnv"
	"math"
	"time"
)

// aggregate is one fake ONTAP aggregate and the controller that owns it.
// Two of them, with deliberately different health and fill, so the panel shows
// both storage states side by side instead of a uniform green estate.
type aggregate struct {
	Name        string
	Node        string
	PolicyGroup string
	Healthy     bool
	CapacityB   float64
	FillRatio   float64
	MaxIOPS     float64
	MaxMBps     float64
}

// estate is fixed inventory: real ONTAP hardware does not appear and disappear
// with Kubernetes claims, so only the volumes below it are discovered.
var estate = []aggregate{
	{
		Name: "aggr1", Node: "ontap-lab-01", PolicyGroup: "pg_gold",
		Healthy: true, CapacityB: 1 << 40, FillRatio: 0.71,
		MaxIOPS: 5000, MaxMBps: 500,
	},
	{
		Name: "aggr2", Node: "ontap-lab-02", PolicyGroup: "pg_silver",
		// Deliberately unhealthy: `node_new_status` 0 is a real reading of
		// "degraded", which the panel must render differently from the series
		// being absent altogether.
		Healthy: false, CapacityB: 2 << 40, FillRatio: 0.19,
		MaxIOPS: 1000, MaxMBps: 100,
	},
}

// placement is the deterministic volume → aggregate assignment. Hashing the PV
// name (rather than round-robin over the discovery order) keeps a claim on the
// same controller across restarts and across claims appearing or disappearing.
func placement(volumeName string) aggregate {
	h := fnv.New32a()
	_, _ = h.Write([]byte(volumeName))
	return estate[int(h.Sum32())%len(estate)]
}

// seed derives a stable per-volume base figure in [lo, hi] from the PV name, so
// two claims never show identical I/O yet each one's profile is reproducible.
func seed(volumeName, metric string, lo, hi float64) float64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(volumeName + "\x00" + metric))
	frac := float64(h.Sum64()%10_000) / 10_000
	return lo + frac*(hi-lo)
}

// wobble applies a slow, phase-shifted oscillation so a live demo shows moving
// numbers. Harvest figures are already-resolved gauges (ops/s, average µs,
// bytes/s) which kube-state-graph reads verbatim — never as a rate() — so these
// must stay bounded around their base and must NOT be monotonic.
func wobble(base float64, now time.Time, phase string) float64 {
	h := fnv.New32a()
	_, _ = h.Write([]byte(phase))
	offset := float64(h.Sum32()%360) / 360 * 2 * math.Pi
	// One full cycle every 10 minutes, phase-shifted per series.
	angle := float64(now.Unix()%600)/600*2*math.Pi + offset
	return base * (1 + 0.25*math.Sin(angle))
}

// promDuration renders a Go duration in the seconds form PromQL accepts.
// time.Duration.String() emits "10m0s", which is not a valid PromQL duration.
func promDuration(d time.Duration) string {
	return fmt.Sprintf("%ds", int64(d.Seconds()))
}
