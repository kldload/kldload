// tree_test.go — the walk, against a Querier that is a map.
//
// The whole reason Build takes an interface is so this file exists: no
// Prometheus, no network, no fixtures on disk, and the failure paths are
// reachable. Table-driven, and every case here is one that has a wrong answer
// worth catching rather than a restatement of the code.

package main

import (
	"errors"
	"strings"
	"testing"
)

// fakeQ answers from a map, and returns an error for any query in its fail
// set — which is how the "exporter is down" path gets tested at all.
type fakeQ struct {
	data map[string][]Sample
	fail map[string]error
}

func (f fakeQ) Query(q string) ([]Sample, error) {
	if err, ok := f.fail[q]; ok {
		return nil, err
	}
	return f.data[q], nil
}

func sample(v float64, kv ...string) Sample {
	l := map[string]string{}
	for i := 0; i+1 < len(kv); i += 2 {
		l[kv[i]] = kv[i+1]
	}
	return Sample{Labels: l, Value: v}
}

func TestBuildGroupsByLabel(t *testing.T) {
	q := fakeQ{data: map[string][]Sample{
		"pools": {
			sample(0, "pool", "rpool"),
			sample(1, "pool", "tank"),
		},
	}}
	root, errs := Build(q, "fiend", []Spec{{
		Title: "Storage", Kind: KindGroup,
		Children: []Spec{{Title: "Pools", Kind: KindPool, Query: "pools", Label: "pool", Format: Health}},
	}})
	if len(errs) != 0 {
		t.Fatalf("unexpected errors: %v", errs)
	}
	pools := root.Children[0].Children[0]
	if got := len(pools.Children); got != 2 {
		t.Fatalf("pools: got %d children, want 2", got)
	}
	// Sorted, so two runs read the same. Prometheus returns series in any order.
	if pools.Children[0].Name != "rpool" || pools.Children[1].Name != "tank" {
		t.Errorf("not sorted by name: %s, %s", pools.Children[0].Name, pools.Children[1].Name)
	}
	if pools.Children[0].Value != "ONLINE" {
		t.Errorf("rpool health: got %q, want ONLINE", pools.Children[0].Value)
	}
	if pools.Children[1].Value != "DEGRADED" {
		t.Errorf("tank health: got %q, want DEGRADED", pools.Children[1].Value)
	}
}

// A failing query must leave a node that SAYS so. A branch that silently
// vanishes when its exporter is down is the failure this whole tool exists to
// make visible, so it is the first thing worth a test.
func TestBuildReportsAFailedBranchInTheTree(t *testing.T) {
	q := fakeQ{fail: map[string]error{"down": errors.New("connection refused")}}
	root, errs := Build(q, "fiend", []Spec{{Title: "Storage", Kind: KindGroup, Query: "down"}})
	if len(errs) != 1 {
		t.Fatalf("got %d errors, want 1", len(errs))
	}
	n := root.Children[0]
	if !strings.Contains(n.Detail, "connection refused") {
		t.Errorf("detail does not name the cause: %q", n.Detail)
	}
	if len(n.Children) != 0 {
		t.Errorf("a failed branch invented %d children", len(n.Children))
	}
}

// Several series can carry the same label value. The largest wins, because
// every one of these is a "how much" question.
func TestBuildTakesTheLargestPerLabel(t *testing.T) {
	q := fakeQ{data: map[string][]Sample{
		"x": {sample(3, "device", "sda"), sample(11, "device", "sda"), sample(7, "device", "sdb")},
	}}
	root, _ := Build(q, "h", []Spec{{Title: "Disks", Kind: KindDisk, Query: "x", Label: "device", Format: Count}})
	got := map[string]string{}
	for _, c := range root.Children[0].Children {
		got[c.Name] = c.Value
	}
	if got["sda"] != "11" {
		t.Errorf("sda: got %q, want 11", got["sda"])
	}
	if got["sdb"] != "7" {
		t.Errorf("sdb: got %q, want 7", got["sdb"])
	}
}

// A series missing the label the spec groups by must be dropped, not turned
// into a row named "". An empty row on a wall display is indistinguishable
// from a rendering bug.
func TestBuildSkipsSeriesMissingTheLabel(t *testing.T) {
	q := fakeQ{data: map[string][]Sample{
		"x": {sample(1, "pool", "rpool"), sample(2, "other", "thing"), sample(3, "pool", "")},
	}}
	root, _ := Build(q, "h", []Spec{{Title: "Pools", Kind: KindPool, Query: "x", Label: "pool"}})
	kids := root.Children[0].Children
	if len(kids) != 1 || kids[0].Name != "rpool" {
		t.Fatalf("got %d rows %v, want just rpool", len(kids), names(kids))
	}
}

// With no Label the spec means "one row per series", and the row has to be
// named by something. Falling back to the whole label set keeps it from being
// blank.
func TestSeriesNamePrefersNameLikeLabels(t *testing.T) {
	cases := []struct {
		name string
		in   map[string]string
		want string
	}{
		{"device wins over job", map[string]string{"job": "node", "device": "sda"}, "sda"},
		{"instance when nothing better", map[string]string{"instance": "localhost:9100"}, "localhost:9100"},
		{"falls back to the whole set", map[string]string{"b": "2", "a": "1"}, "a=1,b=2"},
		{"never blank", map[string]string{}, "(unlabelled)"},
	}
	for _, c := range cases {
		if got := seriesName(c.in); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

func TestCountWalksTheWholeTree(t *testing.T) {
	n := &Node{Children: []*Node{
		{Children: []*Node{{}, {}}},
		{},
	}}
	if got := n.Count(); got != 4 {
		t.Errorf("Count: got %d, want 4", got)
	}
}

// The four views must stay in workspace order, because the command center
// puts view N on workspace N and a silent reorder here would move the wall
// display around with no error anywhere.
func TestViewsAreInCompassOrder(t *testing.T) {
	want := []string{"Network", "Storage", "Compute", "Host"}
	got := Views()
	if len(got) != len(want) {
		t.Fatalf("got %d views, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i].Title != want[i] {
			t.Errorf("view %d: got %q, want %q", i+1, got[i].Title, want[i])
		}
	}
}

// Every branch must name a query or have children. One that does neither is a
// row that can never show anything, which is easy to write and invisible.
func TestEveryViewBranchCanProduceSomething(t *testing.T) {
	var walk func(string, Spec)
	walk = func(path string, s Spec) {
		p := path + "/" + s.Title
		if s.Query == "" && len(s.Children) == 0 {
			t.Errorf("%s has no query and no children — it can never show anything", p)
		}
		for _, c := range s.Children {
			walk(p, c)
		}
	}
	for _, v := range Views() {
		walk("", v)
	}
}

func names(n []*Node) []string {
	out := make([]string, len(n))
	for i, x := range n {
		out[i] = x.Name
	}
	return out
}
