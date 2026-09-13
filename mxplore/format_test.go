// format_test.go — the converters, including the edges that read wrong.

package main

import "testing"

func TestBytes(t *testing.T) {
	cases := []struct {
		in   float64
		want string
	}{
		{0, "0 B"}, {512, "512 B"}, {1024, "1.0 KiB"},
		{1536, "1.5 KiB"}, {1073741824, "1.0 GiB"},
		{14909747200, "13.9 GiB"},
	}
	for _, c := range cases {
		if got := Bytes(c.in); got != c.want {
			t.Errorf("Bytes(%v): got %q, want %q", c.in, got, c.want)
		}
	}
}

// Percent takes a RATIO. The mistake worth a test is passing an already-scaled
// value, which yields a number nobody questions until it says 8500%.
func TestPercentTakesARatio(t *testing.T) {
	if got := Percent(0.85); got != "85.0%" {
		t.Errorf("Percent(0.85): got %q, want 85.0%%", got)
	}
	if got := Percent(85); got != "8500.0%" {
		t.Errorf("Percent(85) should be obviously wrong, got %q", got)
	}
}

func TestSecondsPicksAReadableUnit(t *testing.T) {
	cases := []struct {
		in   float64
		want string
	}{
		{0.000125, "125 µs"}, {0.0125, "12.5 ms"},
		{1.5, "1.50 s"}, {90, "1m30s"},
	}
	for _, c := range cases {
		if got := Seconds(c.in); got != c.want {
			t.Errorf("Seconds(%v): got %q, want %q", c.in, got, c.want)
		}
	}
}

func TestCountGroupsThousands(t *testing.T) {
	cases := []struct {
		in   float64
		want string
	}{
		{0, "0"}, {999, "999"}, {1000, "1,000"},
		{1678, "1,678"}, {1234567, "1,234,567"}, {-4321, "-4,321"},
	}
	for _, c := range cases {
		if got := Count(c.in); got != c.want {
			t.Errorf("Count(%v): got %q, want %q", c.in, got, c.want)
		}
	}
}

// The mapping is zfs_exporter's, not ours; an unknown code must still render
// as something rather than an empty cell.
func TestHealthNamesEveryStateAndTheUnknownOnes(t *testing.T) {
	if got := Health(0); got != "ONLINE" {
		t.Errorf("Health(0): got %q", got)
	}
	if got := Health(2); got != "FAULTED" {
		t.Errorf("Health(2): got %q", got)
	}
	if got := Health(99); got != "state 99" {
		t.Errorf("Health(99): got %q, want a legible fallback", got)
	}
}

// Padding is computed from the visible width, so a coloured name still lines
// its value up with an uncoloured one.
func TestVisibleLenIgnoresEscapes(t *testing.T) {
	if got := visibleLen("\033[1mrpool\033[0m"); got != 5 {
		t.Errorf("visibleLen: got %d, want 5", got)
	}
}
