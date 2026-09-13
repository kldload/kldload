// =============================================================================
// format.go — turning a float into something a person reads at a glance.
//
// Every value in the tree arrives as a bare float64 from Prometheus and leaves
// as a string. The unit is known by whoever wrote the Spec, not by the
// renderer, so the conversion lives with the spec and this file holds the
// handful of converters the specs share.
//
// The rule throughout: three significant figures is enough on a wall display,
// and a unit suffix beats a column header nobody reads.
// =============================================================================

package main

import (
	"fmt"
	"math"
	"strconv"
	"time"
)

// trimFloat prints a number without trailing zeroes: 4 rather than 4.000000,
// 1.5 rather than 1.500000. The default when a Spec names no formatter.
func trimFloat(v float64) string {
	return strconv.FormatFloat(v, 'g', 4, 64)
}

// Bytes renders a byte count in IEC units. 1024, not 1000: these are disks and
// memory, where the powers of two are the honest ones.
func Bytes(v float64) string {
	const unit = 1024.0
	if math.Abs(v) < unit {
		return fmt.Sprintf("%.0f B", v)
	}
	units := []string{"KiB", "MiB", "GiB", "TiB", "PiB", "EiB"}
	n := v
	for _, u := range units {
		n /= unit
		if math.Abs(n) < unit {
			return fmt.Sprintf("%.1f %s", n, u)
		}
	}
	return fmt.Sprintf("%.1f ZiB", n/unit)
}

// Percent takes a RATIO (0..1) and prints it as a percentage. Named for what
// it produces rather than what it consumes, which is the mistake worth calling
// out: passing an already-scaled 0..100 value here yields 8500%.
func Percent(v float64) string {
	return fmt.Sprintf("%.1f%%", v*100)
}

// Seconds renders a duration held as seconds. Sub-second values keep their
// precision because latency lives there; longer ones round.
func Seconds(v float64) string {
	d := time.Duration(v * float64(time.Second))
	switch {
	case math.Abs(v) < 1e-3:
		return fmt.Sprintf("%.0f µs", v*1e6)
	case math.Abs(v) < 1:
		return fmt.Sprintf("%.1f ms", v*1e3)
	case math.Abs(v) < 60:
		return fmt.Sprintf("%.2f s", v)
	default:
		return d.Round(time.Second).String()
	}
}

// Count is a plain integer with thousands separators, for things that are
// counted rather than measured.
func Count(v float64) string {
	n := int64(v)
	s := strconv.FormatInt(n, 10)
	if n < 0 {
		return "-" + group(s[1:])
	}
	return group(s)
}

func group(s string) string {
	if len(s) <= 3 {
		return s
	}
	head := len(s) % 3
	if head == 0 {
		head = 3
	}
	out := s[:head]
	for i := head; i < len(s); i += 3 {
		out += "," + s[i:i+3]
	}
	return out
}

// Health maps ZFS's numeric health to the word an operator wants. The mapping
// is the exporter's, not ours: zfs_exporter publishes 0 for ONLINE.
func Health(v float64) string {
	switch int(v) {
	case 0:
		return "ONLINE"
	case 1:
		return "DEGRADED"
	case 2:
		return "FAULTED"
	case 3:
		return "OFFLINE"
	case 4:
		return "UNAVAIL"
	case 5:
		return "REMOVED"
	default:
		return fmt.Sprintf("state %d", int(v))
	}
}
