package main

import (
	"strings"
	"testing"
)

// navigationKeys are taken by the console itself; a verb on one of them
// would never fire (h and k were hold and bookmark for an afternoon and
// went to "previous section" and "row up" instead, 2026-09-26).
var navigationKeys = map[string]bool{
	"q": true, "?": true, "l": true, "h": true, "tab": true, "[": true, "]": true,
	"1": true, "2": true, "3": true, "4": true, "5": true, "6": true, "7": true, "8": true, "9": true, "0": true,
	"j": true, "k": true, "g": true, "G": true, "/": true, "o": true, "i": true, "r": true, "esc": true, "enter": true, " ": true,
}

func TestVerbKeysDoNotCollideWithNavigation(t *testing.T) {
	for tab, vs := range verbs {
		seen := map[string]bool{}
		for _, v := range vs {
			if navigationKeys[v.key] {
				t.Errorf("%s: verb %q uses navigation key %q", tab, v.label, v.key)
			}
			if seen[v.key] {
				t.Errorf("%s: key %q is bound twice", tab, v.key)
			}
			seen[v.key] = true
			if v.argv == nil && v.ctxArgv == nil && v.rowCtxArgv == nil {
				t.Errorf("%s: verb %q builds no command", tab, v.label)
			}
		}
	}
}

func TestEveryTabHasACollector(t *testing.T) {
	for _, s := range sections {
		for _, sub := range s.subs {
			if _, ok := collectors[s.name+"/"+sub]; !ok {
				t.Errorf("%s/%s has no collector", s.name, sub)
			}
		}
	}
	for key := range verbs {
		sec, sub, _ := strings.Cut(key, "/")
		i := sectionIndex(sec)
		if i < 0 || subIndex(i, sub) < 0 {
			t.Errorf("verbs for %q, which is not a tab", key)
		}
	}
}
