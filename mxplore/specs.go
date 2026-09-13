// =============================================================================
// specs.go — which four views the machine has, and what hangs under each.
//
// This file is the opinion. Everything else in mxplore is mechanism; this is
// the part that says a machine is made of storage, compute, network and
// kernel, and that those are the four things worth a workspace each.
//
// The order matches the desktop's compass layout, because the command center
// puts view N on workspace N and a mismatch between the two would be a very
// annoying bug to have to remember: 1 north, 2 west, 3 east, 4 south.
//
// EVERY QUERY HERE NAMES AN EXPORTER kldload SHIPS. They are listed against
// each branch so a branch that reads "unavailable" points at the thing to go
// and start, rather than at this file.
// =============================================================================

package main

// Views returns the four top-level branches, in workspace order.
//
// A branch whose exporter is absent renders as one line saying so. That is the
// designed behaviour, not a gap: on a machine with no VMs the compute view
// SHOULD say there are none rather than quietly not existing.
func Views() []Spec {
	return []Spec{networkView(), storageView(), computeView(), hostView()}
}

// ── 1, north — network and eBPF ──────────────────────────────────────────────
// Sources: node_exporter (interfaces), Cilium and Hubble (flows), Tetragon
// (syscalls). The kernel's own view of the network, which is the one that is
// true when the application's view disagrees.
func networkView() Spec {
	return Spec{
		Title: "Network",
		Kind:  KindGroup,
		Children: []Spec{
			{
				Title: "Interfaces", Kind: KindIface,
				Query: "node_network_up", Label: "device",
			},
			{
				Title: "Receive", Kind: KindIface,
				Query:  "rate(node_network_receive_bytes_total[5m])",
				Label:  "device",
				Format: func(v float64) string { return Bytes(v) + "/s" },
			},
			{
				Title: "Transmit", Kind: KindIface,
				Query:  "rate(node_network_transmit_bytes_total[5m])",
				Label:  "device",
				Format: func(v float64) string { return Bytes(v) + "/s" },
			},
			{
				Title: "Hubble flows", Kind: KindProbe,
				Query:  "sum by (protocol) (rate(hubble_flows_processed_total[5m]))",
				Label:  "protocol",
				Format: func(v float64) string { return Count(v) + "/s" },
			},
			{
				Title: "Tetragon events", Kind: KindProbe,
				Query:  "sum by (type) (rate(tetragon_events_total[5m]))",
				Label:  "type",
				Format: func(v float64) string { return Count(v) + "/s" },
			},
		},
	}
}

// ── 2, west — storage and ZFS ────────────────────────────────────────────────
// Sources: zfs_exporter (pools, ARC), smartctl_exporter (disks),
// ebpf_exporter (block latency, from the biolatency programs).
func storageView() Spec {
	return Spec{
		Title: "Storage",
		Kind:  KindGroup,
		Children: []Spec{
			{
				Title: "Pools", Kind: KindPool,
				Query: "zfs_pool_health", Label: "pool", Format: Health,
			},
			{
				Title: "Allocated", Kind: KindPool,
				Query: "zfs_pool_allocated_bytes", Label: "pool", Format: Bytes,
			},
			{
				Title: "Free", Kind: KindPool,
				Query: "zfs_pool_free_bytes", Label: "pool", Format: Bytes,
			},
			{
				Title: "Disks", Kind: KindDisk,
				Query: "smartctl_device_temperature", Label: "device",
				Format: func(v float64) string { return trimFloat(v) + " °C" },
			},
			{
				// p99 out of the histogram, NOT the _sum counter. The first
				// version of this line read topk(5, ..._seconds_sum), which is
				// a monotonic total since boot: onyx rendered "33m48s" as a
				// block latency and it looked like a catastrophe rather than a
				// units mistake (2026-09-13). A histogram's sum is not a
				// latency and never was.
				Title: "Block latency p99", Kind: KindProbe,
				Query:  "histogram_quantile(0.99, sum by (device, le) (rate(ebpf_exporter_bio_latency_seconds_bucket[5m])))",
				Label:  "device",
				Format: Seconds,
			},
			{
				// klab-exporter, not node_exporter: the node_exporter unit
				// runs with --no-collector.zfs because it double-counts
				// against zfs_exporter, so node_zfs_arc_size does not exist on
				// a kldload machine. Checked against a live Prometheus rather
				// than assumed — the name I reached for first returned zero
				// series.
				Title: "ARC size", Kind: KindGroup,
				Query: "klab_zfs_arc_size_bytes", Format: Bytes,
			},
			{
				// The number that actually tells you whether the ARC is doing
				// its job. A ratio in 0..1, which is what Percent wants.
				Title: "ARC hit ratio", Kind: KindGroup,
				Query: "klab_zfs_arc_hit_ratio", Format: Percent,
			},
		},
	}
}

// ── 3, east — cluster and guests ─────────────────────────────────────────────
// Sources: libvirt-exporter (guests), kubelet and the Cilium agent (nodes).
func computeView() Spec {
	return Spec{
		Title: "Compute",
		Kind:  KindGroup,
		Children: []Spec{
			{
				Title: "Guests", Kind: KindGuest,
				Query: "libvirt_domain_info_state", Label: "domain",
			},
			{
				Title: "Guest memory", Kind: KindGuest,
				Query: "libvirt_domain_info_memory_usage_bytes", Label: "domain",
				Format: Bytes,
			},
			{
				Title: "Cluster nodes", Kind: KindNode,
				Query: "kubelet_node_name", Label: "node",
			},
			{
				Title: "Running pods", Kind: KindNode,
				Query:  "sum by (node) (kubelet_running_pods)",
				Label:  "node",
				Format: Count,
			},
		},
	}
}

// ── 4, south — the host itself ───────────────────────────────────────────────
// Sources: node_exporter and process-exporter. The floor everything else
// stands on, and the first place to look when every other view is strange.
func hostView() Spec {
	return Spec{
		Title: "Host",
		Kind:  KindGroup,
		Children: []Spec{
			{
				Title: "Load", Kind: KindGroup,
				Query: "node_load1",
			},
			{
				Title: "Memory available", Kind: KindGroup,
				Query: "node_memory_MemAvailable_bytes", Format: Bytes,
			},
			{
				Title: "Filesystem used", Kind: KindDisk,
				Query: "1 - (node_filesystem_avail_bytes / node_filesystem_size_bytes)",
				Label: "mountpoint", Format: Percent,
			},
			{
				Title: "Top processes", Kind: KindProcess,
				Query:  "topk(8, sum by (groupname) (rate(namedprocess_namegroup_cpu_seconds_total[5m])))",
				Label:  "groupname",
				Format: Percent,
			},
		},
	}
}
