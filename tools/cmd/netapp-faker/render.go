package main

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

const (
	kib = 1 << 10
	gib = 1 << 30

	// Fallback claim capacity, used only when kube-state-metrics did not expose
	// the claim's requested size.
	fallbackClaimCapacityB = 10 * gib
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
	for _, c := range claims {
		for _, s := range claimSamples(cfg, c, now) {
			writeSample(&b, cfg, s)
		}
	}
	return b.String()
}

// estateSamples covers the fixed hardware: aggregate health and space,
// controller health, and the declared QoS ceilings (hop C of the join).
func estateSamples(cfg config, now time.Time) []sample {
	out := make([]sample, 0, len(estate)*6)
	for _, a := range estate {
		aggrLabels := map[string]string{"cluster": cfg.OntapCluster, "node": a.Node, "aggr": a.Name}
		nodeLabels := map[string]string{"cluster": cfg.OntapCluster, "node": a.Node}
		policyLabels := map[string]string{"cluster": cfg.OntapCluster, "svm": cfg.SVM, "name": a.PolicyGroup}

		out = append(out,
			sample{"aggr_new_status", aggrLabels, boolValue(a.Healthy)},
			sample{"aggr_space_total", aggrLabels, a.CapacityB},
			sample{"aggr_space_used", aggrLabels, wobble(a.CapacityB*a.FillRatio, now, a.Name+"space")},
			sample{"node_new_status", nodeLabels, boolValue(a.Healthy)},
			sample{"qos_policy_fixed_max_throughput_iops", policyLabels, a.MaxIOPS},
			sample{"qos_policy_fixed_max_throughput_mbps", policyLabels, a.MaxMBps},
		)
	}
	return out
}

// claimSamples covers one discovered PVC: the topology hop that gives it a
// storage chain at all, then the I/O hop that gives that chain numbers.
func claimSamples(cfg config, c claim, now time.Time) []sample {
	a := placement(c.VolumeName)

	// Hop A. The ONLY join kube-state-graph performs on the storage side is
	// kube_persistentvolumeclaim_info.volumename == volume_labels.volume_name.
	// `volume_name` is not a stock Harvest label; a real deployment stamps it
	// with a relabel rule, and here we simply write the PV name we discovered.
	topology := map[string]string{
		"cluster":     cfg.OntapCluster, // ONTAP cluster — never a Kubernetes one
		"node":        a.Node,
		"aggr":        a.Name,
		"svm":         cfg.SVM,
		"volume_name": c.VolumeName,
	}
	// Hop B. Rendered WITHOUT a `lun` label: the query is issued as
	// qos_*{lun=""}, and an empty-string matcher also matches series carrying
	// no such label, so volume-granularity series are picked up unchanged.
	// `policy_group` here is what joins this volume to its ceiling in hop C.
	workload := map[string]string{
		"cluster":      cfg.OntapCluster,
		"svm":          cfg.SVM,
		"policy_group": a.PolicyGroup,
		"volume_name":  c.VolumeName,
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

	// The kubelet legs are a stand-in for a kubelet that reports nothing for
	// this volume plugin — not part of the NetApp simulation. Off by default;
	// see the chart values for when turning them on is honest.
	if cfg.VolumeStats {
		claimLabels := map[string]string{
			"cluster":               c.Cluster, // Kubernetes cluster here, not ONTAP
			"namespace":             c.Namespace,
			"persistentvolumeclaim": c.Name,
		}
		capacity := c.CapacityB
		if capacity <= 0 {
			capacity = fallbackClaimCapacityB
		}
		used := wobble(seed(c.VolumeName, "used", 0.25, 0.85)*capacity, now, c.VolumeName+"u")
		out = append(out,
			sample{"kubelet_volume_stats_capacity_bytes", claimLabels, capacity},
			sample{"kubelet_volume_stats_used_bytes", claimLabels, used},
		)
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
