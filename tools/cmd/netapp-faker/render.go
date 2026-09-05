package main

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

const (
	kib = 1 << 10
	mib = 1 << 20
)

type sample struct {
	Name   string
	Labels map[string]string
	Value  float64
}

// render produces the Prometheus exposition text for one tick.
//
// Everything here is a GAUGE re-pushed at a steady-ish value, which is the
// opposite of what the service-graph counters need. kube-state-graph reads the
// Harvest families with last_over_time and takes the value verbatim: Harvest
// has already resolved ONTAP's base counters, so `qos_read_ops` is ALREADY
// per-second and `qos_*_latency` is ALREADY an average in microseconds. Making
// these monotonic would render absurd figures in the panel.
func render(cfg config, claims []claim, now time.Time) string {
	var b strings.Builder
	for _, s := range estateSamples(cfg, now) {
		writeSample(&b, cfg, s)
	}
	// The claim's RANK, not its name, decides which aggregate it lands on —
	// discover already returns them sorted, so the rank is stable.
	for rank, c := range claims {
		for _, s := range claimSamples(cfg, c, rank, now) {
			writeSample(&b, cfg, s)
		}
	}
	return b.String()
}

// estateSamples covers the fixed hardware: the controller tier, the aggregate
// tier, and the declared QoS ceilings (hop C of the join).
func estateSamples(cfg config, now time.Time) []sample {
	out := make([]sample, 0, len(controllers)*6+len(estate)*5)
	out = append(out, controllerSamples(cfg, now)...)

	for _, a := range estate {
		aggrLabels := map[string]string{"cluster": cfg.OntapCluster, "node": a.Node, "aggr": a.Name}
		policyLabels := map[string]string{"cluster": cfg.OntapCluster, "svm": cfg.SVM, "name": a.PolicyGroup}

		out = append(out,
			sample{"aggr_new_status", aggrLabels, boolValue(a.Healthy)},
			sample{"aggr_space_total", aggrLabels, a.CapacityB},
			sample{"aggr_space_used", aggrLabels, wobble(a.CapacityB*a.FillRatio, now, a.Name+"space")},
			sample{"qos_policy_fixed_max_throughput_iops", policyLabels, a.MaxIOPS},
			sample{"qos_policy_fixed_max_throughput_mbps", policyLabels, a.MaxMBps},
		)
	}
	return out
}

// controllerSamples renders the ONTAP node tier: health, hardware identity and
// the four system_node performance counters.
//
// All three legs are OPTIONAL to kube-state-graph and degrade independently —
// a controller with no node_labels keeps its health and loses `data.hardware`,
// one counter missing leaves that one field nil rather than zero. They are all
// rendered here because a demo of the storage graph that shows an unidentified
// controller with no load teaches nothing about what the tier is for.
func controllerSamples(cfg config, now time.Time) []sample {
	out := make([]sample, 0, len(controllers)*6)
	for _, c := range controllers {
		key := map[string]string{"cluster": cfg.OntapCluster, "node": c.Name}

		// An INFO series: the value is ignored and only the labels are read.
		// `ha_partner` is a stock instance key too, but this estate has no HA
		// pairs to name and inventing one would put a controller in the graph
		// that no other series mentions.
		identity := map[string]string{
			"cluster":  cfg.OntapCluster,
			"node":     c.Name,
			"model":    c.Model,
			"serial":   c.Serial,
			"version":  c.Version,
			"vendor":   c.Vendor,
			"location": c.Location,
		}

		// Read verbatim, never rate()d: Harvest has already resolved ONTAP's
		// base counters, so cpu_busy is a percent, total_ops per-second,
		// total_latency an average in microseconds and total_data bytes/s.
		out = append(out,
			sample{"node_new_status", key, boolValue(c.Healthy)},
			sample{"node_labels", identity, 1},
			sample{"node_cpu_busy", key, wobble(c.CPUBusyPct, now, c.Name+"cpu")},
			sample{"node_total_ops", key, wobble(c.TotalOps, now, c.Name+"ops")},
			sample{"node_total_latency", key, wobble(c.TotalLatencyUs, now, c.Name+"lat")},
			sample{"node_total_data", key, wobble(c.TotalBytesPerSec, now, c.Name+"data")},
		)
	}
	return out
}

// flexVolName derives the ONTAP FlexVol name a CSI provisioner would give a
// PersistentVolume: every `-` becomes `_` (ONTAP volume names admit only
// letters, digits and `_`, so a `pvc-<uuid>` name is not a legal one) and the
// backend's storagePrefix goes in front.
//
// This is the faker's half of a join it must NOT short-circuit.
// kube-state-graph runs the same rewrite over the claim's `volumename` and
// SUFFIX-matches the result against the stock Harvest `volume` label — it is
// never told what the prefix is. Writing the PV name here verbatim would make
// the two sides meet trivially and prove nothing; writing it under a prefix is
// what exercises the derivation the real estate depends on.
func flexVolName(prefix, volumeName string) string {
	return prefix + strings.ReplaceAll(volumeName, "-", "_")
}

// claimSamples covers one discovered PVC: the topology hop that gives it a
// storage chain at all, then the I/O hop that gives that chain numbers.
func claimSamples(cfg config, c claim, rank int, now time.Time) []sample {
	a := placement(rank)
	vol := flexVolName(cfg.StoragePrefix, c.VolumeName)

	// Hop A. `volume` is the STOCK Harvest label naming the FlexVol, and it is
	// the only one kube-state-graph reads: it derives a match token from
	// kube_persistentvolumeclaim_info.volumename and compares it against this
	// value. No relabel rule stamps a PV-name label onto Harvest series, and a
	// deployment that installs one has it ignored.
	topology := map[string]string{
		"cluster": cfg.OntapCluster, // ONTAP cluster — never a Kubernetes one
		"node":    a.Node,
		"aggr":    a.Name,
		"svm":     cfg.SVM,
		"volume":  vol,
	}
	// Hop B. Rendered WITHOUT a `lun` label: the reader sums only candidates
	// whose `lun` is empty, so volume-granularity series are picked up while a
	// LUN workload of the same FlexVol would be discarded. `policy_group` here
	// is what joins this volume to its ceiling in hop C. The `volume` label is
	// also the scope the second-wave QoS query is restricted to, so it has to
	// carry exactly the value hop A matched.
	workload := map[string]string{
		"cluster":      cfg.OntapCluster,
		"svm":          cfg.SVM,
		"policy_group": a.PolicyGroup,
		"volume":       vol,
	}

	readOps := wobble(seed(c.VolumeName, "read_ops", 40, 400), now, c.VolumeName+"r")
	writeOps := wobble(seed(c.VolumeName, "write_ops", 5, 120), now, c.VolumeName+"w")

	out := []sample{
		{"volume_labels", topology, 1},
		{"qos_read_ops", workload, readOps},
		{"qos_write_ops", workload, writeOps},
		{"qos_read_latency", workload, wobble(seed(c.VolumeName, "read_lat", 180, 1500), now, c.VolumeName+"rl")},
		{"qos_write_latency", workload, wobble(seed(c.VolumeName, "write_lat", 400, 3000), now, c.VolumeName+"wl")},
		// Already bytes/s, matching what Harvest reports for the data families.
		{"qos_read_data", workload, readOps * 32 * kib},
		{"qos_write_data", workload, writeOps * 16 * kib},
	}

	return out
}

// writeSample renders one series, merging in the operator-supplied external
// labels (az / env). Those are a hard precondition of the filtered build: the
// az / env request filters are pushed upstream as raw matchers against every
// topology family, this one included.
func writeSample(b *strings.Builder, cfg config, s sample) {
	merged := make(map[string]string, len(s.Labels)+len(cfg.ExtraLabels))
	for k, v := range cfg.ExtraLabels {
		merged[k] = v
	}
	for k, v := range s.Labels {
		merged[k] = v
	}

	b.WriteString(s.Name)
	b.WriteByte('{')
	for i, k := range sortedKeys(merged) {
		if i > 0 {
			b.WriteByte(',')
		}
		fmt.Fprintf(b, "%s=%q", k, merged[k])
	}
	b.WriteString("} ")
	b.WriteString(strconv.FormatFloat(s.Value, 'f', -1, 64))
	b.WriteByte('\n')
}

func boolValue(ok bool) float64 {
	if ok {
		return 1
	}
	return 0
}
