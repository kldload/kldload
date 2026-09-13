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
				Title: "Block latency", Kind: KindProbe,
				Query: "topk(5, ebpf_exporter_bio_latency_seconds_sum)", Label: "device",
				Format: Seconds,
			},
			{
				Title: "ARC size", Kind: KindGroup,
				Query: "node_zfs_arc_size", Format: Bytes,
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
