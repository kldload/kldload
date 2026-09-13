// =============================================================================
// tree.go — the shape of a machine, as something you can walk into.
//
// WHAT THIS IS: the model behind mxplore. A machine is a tree — a pool has
// vdevs, a vdev has disks, a guest has virtual disks, a cgroup has processes —
// and the interesting question is almost always "which one", asked repeatedly
// until you reach a thing with a name.
//
// WHY A TREE AND NOT A DASHBOARD: Grafana is very good at a time series and
// very bad at hierarchy. Answering "which disk in which vdev in which pool is
// slow" on a dashboard means knowing the answer first so you can pick the
// right variable from a dropdown. Walking in does not.
//
// WHY A SPEC RATHER THAN CODE PER BRANCH: every branch here is the same three
// facts — a query, the label that names each child, and the value to show
// beside it. Writing that as data means a new branch is a Spec literal rather
// than a function, and it means the walk can be tested against fixture JSON
// with no Prometheus anywhere near it.
//
// Notes:
//   - Nothing here talks to the network. Build takes a Querier, which prom.go
//     implements against Prometheus and the tests implement against a map.
//     That split is the only reason this file is testable at all.
// =============================================================================

package main

import (
	"fmt"
	"sort"
	"strings"
)

// Kind is what a node IS, which decides how it is drawn and what can be done
// to it later. Deliberately a small closed set: an open-ended string here
// would become a second, undocumented vocabulary within a week.
type Kind string

const (
	KindHost    Kind = "host"
	KindGroup   Kind = "group"
	KindPool    Kind = "pool"
	KindVdev    Kind = "vdev"
	KindDisk    Kind = "disk"
	KindGuest   Kind = "guest"
	KindNode    Kind = "node"
	KindProcess Kind = "process"
	KindIface   Kind = "iface"
	KindProbe   Kind = "probe"
)

// Node is one row in the tree. Value is already formatted for display: the
// formatting decision belongs to whoever knows the unit, which is the Spec,
// not the renderer.
type Node struct {
	Name     string
	Kind     Kind
	Value    string
	Detail   string
	Children []*Node
}

// Spec describes one branch: run Query, make a child per distinct value of
// Label, and show Format applied to the sample's value.
//
// Empty Label means "one child per series, named by the metric itself" — used
// for leaf groups like host summary lines.
type Spec struct {
	Title    string
	Kind     Kind
	Query    string
	Label    string
	Format   func(float64) string
	Children []Spec
	// Filter narrows a child branch to the parent it belongs under, by
	// substituting %s with the parent's name. Empty means the branch does not
	// depend on its parent, which is true of the top-level groups.
	Filter string
}

// Querier is the one thing the model needs from the outside world: run an
// instant query, get back label sets and values. prom.go satisfies it over
// HTTP; tree_test.go satisfies it with a literal map.
type Querier interface {
	Query(q string) ([]Sample, error)
}

// Sample is one returned series: its labels and its instantaneous value.
type Sample struct {
	Labels map[string]string
	Value  float64
}

// Build walks the spec and returns the root of a live tree.
//
// Returns a tree even when queries fail: a branch whose query errors becomes a
// node that SAYS it failed rather than a branch that silently is not there.
// The whole point of this tool is noticing what is missing, so a missing
// branch must be visible. Errors are collected and returned alongside, for a
// caller that wants to exit non-zero.
func Build(q Querier, host string, specs []Spec) (*Node, []error) {
	root := &Node{Name: host, Kind: KindHost}
	var errs []error
	for _, s := range specs {
		child, e := buildOne(q, s, "")
		errs = append(errs, e...)
		root.Children = append(root.Children, child)
	}
	return root, errs
}

func buildOne(q Querier, s Spec, parent string) (*Node, []error) {
	n := &Node{Name: s.Title, Kind: s.Kind}
	var errs []error

	query := s.Query
	if s.Filter != "" && parent != "" {
		query = fmt.Sprintf(s.Filter, parent)
	}

	if query != "" {
		samples, err := q.Query(query)
		if err != nil {
			// Loud, in the tree itself. A branch that quietly vanishes when
			// its exporter is down is how you end up trusting a view that is
			// lying to you by omission.
			n.Detail = "unavailable: " + err.Error()
			errs = append(errs, fmt.Errorf("%s: %w", s.Title, err))
			return n, errs
		}
		n.Children = append(n.Children, samplesToNodes(samples, s)...)
	}

	// Sub-branches hang off each child produced above, or off this node
	// directly when this spec produced no children of its own.
	for _, sub := range s.Children {
		if len(n.Children) > 0 && sub.Filter != "" {
			for _, c := range n.Children {
				sn, e := buildOne(q, sub, c.Name)
				errs = append(errs, e...)
				c.Children = append(c.Children, sn)
			}
			continue
		}
		sn, e := buildOne(q, sub, parent)
		errs = append(errs, e...)
		n.Children = append(n.Children, sn)
	}
	return n, errs
}

// samplesToNodes turns a query result into child rows, one per distinct value
// of the spec's label, sorted by name so two runs of the same tree read the
// same way. Prometheus returns series in whatever order it likes.
func samplesToNodes(samples []Sample, s Spec) []*Node {
	if s.Label == "" {
		// One row per series, named by whatever identifies it. Used for
		// summary branches where there is nothing to drill into.
		out := make([]*Node, 0, len(samples))
		for _, sm := range samples {
			out = append(out, &Node{
				Name:  seriesName(sm.Labels),
				Kind:  s.Kind,
				Value: format(s, sm.Value),
			})
		}
		sortNodes(out)
		return out
	}

	// Group by label. Several series can carry the same label value; the
	// largest wins, because these are all "how much" questions and the
	// interesting one is the biggest.
	best := map[string]float64{}
	for _, sm := range samples {
		v, ok := sm.Labels[s.Label]
		if !ok || v == "" {
			continue
		}
		if cur, seen := best[v]; !seen || sm.Value > cur {
			best[v] = sm.Value
		}
	}
	out := make([]*Node, 0, len(best))
	for name, v := range best {
		out = append(out, &Node{Name: name, Kind: s.Kind, Value: format(s, v)})
	}
	sortNodes(out)
	return out
}

func format(s Spec, v float64) string {
	if s.Format == nil {
		return trimFloat(v)
	}
	return s.Format(v)
}

func sortNodes(n []*Node) {
	sort.Slice(n, func(i, j int) bool { return n[i].Name < n[j].Name })
}

// seriesName picks the most name-like label available, falling back to the
// whole label set so a row is never blank.
func seriesName(l map[string]string) string {
	for _, k := range []string{"name", "device", "instance", "pool", "job"} {
		if v, ok := l[k]; ok && v != "" {
			return v
		}
	}
	keys := make([]string, 0, len(l))
	for k := range l {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for i, k := range keys {
		if i > 0 {
			b.WriteString(",")
		}
		fmt.Fprintf(&b, "%s=%s", k, l[k])
	}
	if b.Len() == 0 {
		return "(unlabelled)"
	}
	return b.String()
}

// Count returns how many nodes hang below n, itself excluded. Used by the
// renderers to decide whether a branch is worth expanding by default.
func (n *Node) Count() int {
	c := 0
	for _, ch := range n.Children {
		c += 1 + ch.Count()
	}
	return c
}
