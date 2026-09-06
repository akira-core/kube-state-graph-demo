package main

import (
	"fmt"
	"hash/fnv"
	"math"
	"time"
)

// controller is one fake ONTAP node: the hardware identity Harvest publishes as
// `node_labels`, and the four `system_node` counters it publishes as
// `node_cpu_busy` / `node_total_ops` / `node_total_latency` / `node_total_data`.
//
// The perf figures are BASE values, wobbled per tick. kube-state-graph carries
// them through to `data.perf` verbatim and never turns them into a health
// verdict, so the two controllers can differ in load without the pipeline
// declaring either one good or bad.
type controller struct {
	Name     string
	Model    string
	Serial   string
	Version  string
	Vendor   string
	Location string
	// Healthy drives `node_new_status`. Separate from the aggregate's own
	// health below: a healthy controller can own a filling aggregate and a
	// degraded one can own a healthy aggregate, and the graph has to be able to
	// show that rather than one verdict smeared across both tiers.
	Healthy          bool
	CPUBusyPct       float64
	TotalOps         float64
	TotalLatencyUs   float64
	TotalBytesPerSec float64
}

// controllers is fixed inventory, like the aggregates below: real ONTAP
// hardware does not appear and disappear with Kubernetes claims.
var controllers = []controller{
	{
		Name: "ontap-lab-01", Model: "AFF-A400", Serial: "701234000001",
		Version: "9.14.1", Vendor: "NetApp", Location: "lab-rack-1",
		Healthy: true, CPUBusyPct: 34, TotalOps: 12000,
		TotalLatencyUs: 420, TotalBytesPerSec: 380 * mib,
	},
	{
		Name: "ontap-lab-02", Model: "FAS2720", Serial: "701234000002",
		Version: "9.12.1", Vendor: "NetApp", Location: "lab-rack-2",
		// Deliberately unhealthy: `node_new_status` 0 is a real reading of
		// "degraded", which the front end must render differently from the
		// series being absent altogether. An older, smaller box working harder.
		Healthy: false, CPUBusyPct: 78, TotalOps: 4200,
		TotalLatencyUs: 1850, TotalBytesPerSec: 96 * mib,
	},
}

// aggregate is one fake ONTAP aggregate and the controller that owns it.
// Two of them, with deliberately different health and fill, so the front end
// shows both storage states side by side instead of a uniform green estate.
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
		Healthy: false, CapacityB: 2 << 40, FillRatio: 0.19,
		MaxIOPS: 1000, MaxMBps: 100,
	},
}

// placement is the deterministic volume → aggregate assignment: rank over the
// sorted claim list, round-robin across the estate.
//
// This used to hash the PV name, which kept a claim on the same aggregate no
// matter which other claims existed. It also let every claim land on ONE
// aggregate by chance — with three claims over two aggregates that is a 25%
// outcome, and it is what happened — leaving the other controller drawn with no
// flow through it at all. Two aggregates of different health only teach
// something if BOTH carry claims, so rank wins over hash stability here. The
// claim set is fixed by charts/demo-workloads/values.yaml, so nothing moves in
// practice; a claim added there can re-place the ones after it.
func placement(rank int) aggregate {
	return estate[rank%len(estate)]
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
