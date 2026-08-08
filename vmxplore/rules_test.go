// rules_test.go — the embedded rulesets must classify and group the real
// estate's naming conventions; these names are copied from a live host.
package main

import "testing"

func kldloadRS(t *testing.T) *Ruleset {
	t.Helper()
	rs, err := ParseRules(kldloadRules, "test:kldload")
	if err != nil {
		t.Fatalf("embedded kldload rules do not parse: %v", err)
	}
	return rs
}

func TestClassifySnap(t *testing.T) {
	rs := kldloadRS(t)
	cases := map[string]string{
		"autosnap_2026-08-07_15:00:02_frequently": "noise",
		"auto-20260807-150000":                    "noise",
		"manual-before-upgrade":                   "human",
		"golden":                                  "golden",
		"clone-20260705_143916906897718":          "provenance",
		"create-20260705":                         "provenance",
		"pre-kube-init-20260705":                  "checkpoint",
		"repl-fiend-20260801":                     "repl",
		"my-adhoc-snap":                           "human", // unmatched → human
	}
	for name, want := range cases {
		if got := rs.ClassifySnap(name); got != want {
			t.Errorf("ClassifySnap(%q) = %q, want %q", name, got, want)
		}
	}
}

func TestGroupFor(t *testing.T) {
	rs := kldloadRS(t)
	cases := map[string]string{
		"k8s-golden":         "goldens",
		"klab-golden-fedora": "goldens",
		"win-10-golden":      "goldens",
		"klab-blue-fedora":   "klab",
		"klab-green-ubuntu":  "klab",
		"klab-ztest-debian":  "klab",
		"kspawn-demo-01":     "kspawn: demo",
		"kldload-cp":         "k8s: kldload",
		"kldload-w-2":        "k8s: kldload", // dashed worker form on the live estate
		"demo-leftover":      "",             // ungrouped
	}
	for name, want := range cases {
		if got := rs.GroupFor(name); got != want {
			t.Errorf("GroupFor(%q) = %q, want %q", name, got, want)
		}
	}
}

func TestSnapSummary(t *testing.T) {
	rs := kldloadRS(t)
	sum := rs.SnapSummary([]string{
		"autosnap_a", "autosnap_b", "manual-x", "golden", "clone-1",
	})
	if sum["noise"] != 2 || sum["human"] != 1 || sum["golden"] != 1 ||
		sum["provenance"] != 1 {
		t.Errorf("SnapSummary wrong: %v", sum)
	}
}

func TestParseRulesRejectsGarbage(t *testing.T) {
	if _, err := ParseRules("frobnicate all the things", "t"); err == nil {
		t.Error("garbage directive parsed without error")
	}
	if _, err := ParseRules("group ((( broken", "t"); err == nil {
		t.Error("bad regex parsed without error")
	}
}

func TestGenericRulesParse(t *testing.T) {
	rs, err := ParseRules(genericRules, "test:generic")
	if err != nil {
		t.Fatalf("embedded generic rules do not parse: %v", err)
	}
	if got := rs.ClassifySnap("zfs-auto-snap_hourly-2026-08-07"); got != "noise" {
		t.Errorf("generic noise classification broken: %q", got)
	}
	if got := rs.GroupFor("anything"); got != "" {
		t.Errorf("generic ruleset should not group, got %q", got)
	}
}
