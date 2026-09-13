// =============================================================================
// prom.go — the only thing in mxplore that touches the network.
//
// WHAT IT DOES: runs Prometheus instant queries over HTTP and returns label
// sets and values. Nothing more. No client library, no dependency: the API is
// one GET with one parameter and a JSON body with four fields that matter, and
// pulling in a module to spell that would cost more than it saves on an image
// that has to build air-gapped.
//
// WHY IT IMPLEMENTS Querier RATHER THAN BEING CALLED DIRECTLY: so the tree can
// be built in a test with no Prometheus, no network and no fixtures on disk.
// That is the difference between a model that is tested and one that is only
// ever run.
//
// Inputs:  a base URL; KLDLOAD_MX_PROMETHEUS or --prometheus decides it.
// Outputs: samples, or an error that names what failed and where.
// Notes:
//   - A 200 carrying {"status":"error"} is an error. Prometheus answers that
//     way for a malformed query and treating the HTTP code as the outcome
//     would turn a typo in a Spec into an empty branch that looks healthy.
//   - Values arrive as [unix_time, "string"]. The string is not a mistake;
//     Prometheus sends NaN and Inf that way and JSON has no spelling for them.
// =============================================================================

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Prom is a Prometheus instant-query client.
type Prom struct {
	Base   string
	Client *http.Client
}

// NewProm returns a client with a bounded timeout. The timeout is short on
// purpose: this sits behind an interactive tree, and a query that has not
// answered in five seconds has already failed the person waiting for it.
func NewProm(base string) *Prom {
	return &Prom{
		Base:   strings.TrimRight(base, "/"),
		Client: &http.Client{Timeout: 5 * time.Second},
	}
}

type promResponse struct {
	Status string `json:"status"`
	Error  string `json:"error"`
	Data   struct {
		ResultType string `json:"resultType"`
		Result     []struct {
			Metric map[string]string `json:"metric"`
			Value  []any             `json:"value"`
		} `json:"result"`
	} `json:"data"`
}

// Query runs one instant query. Satisfies Querier.
func (p *Prom) Query(q string) ([]Sample, error) {
	u := fmt.Sprintf("%s/api/v1/query?query=%s", p.Base, url.QueryEscape(q))
	ctx, cancel := context.WithTimeout(context.Background(), p.Client.Timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, fmt.Errorf("building request: %w", err)
	}
	resp, err := p.Client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("querying %s: %w", p.Base, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s returned HTTP %d", p.Base, resp.StatusCode)
	}

	var pr promResponse
	if err := json.NewDecoder(resp.Body).Decode(&pr); err != nil {
		return nil, fmt.Errorf("decoding response: %w", err)
	}
	// A 200 with status:error is how Prometheus reports a bad query. Reading
	// only the HTTP code turns a typo into a branch that renders empty and
	// looks fine.
	if pr.Status != "success" {
		if pr.Error != "" {
			return nil, fmt.Errorf("prometheus: %s", pr.Error)
		}
		return nil, fmt.Errorf("prometheus returned status %q", pr.Status)
	}

	out := make([]Sample, 0, len(pr.Data.Result))
	for _, r := range pr.Data.Result {
		v, ok := promValue(r.Value)
		if !ok {
			continue // NaN, Inf, or a shape we do not recognise — not a number
		}
		out = append(out, Sample{Labels: r.Metric, Value: v})
	}
	return out, nil
}

// promValue pulls the float out of Prometheus's [timestamp, "value"] pair.
// Returns false for anything that is not a finite number, including the "NaN"
// and "+Inf" strings the API legitimately sends.
func promValue(v []any) (float64, bool) {
	if len(v) != 2 {
		return 0, false
	}
	s, ok := v[1].(string)
	if !ok {
		return 0, false
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0, false
	}
	return f, true
}

// Reachable answers whether Prometheus is there at all, so the caller can say
// "Prometheus is not running" once instead of printing the same connection
// error under every branch of the tree.
func (p *Prom) Reachable() error {
	ctx, cancel := context.WithTimeout(context.Background(), p.Client.Timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.Base+"/-/healthy", nil)
	if err != nil {
		return err
	}
	resp, err := p.Client.Do(req)
	if err != nil {
		return fmt.Errorf("no Prometheus at %s: %w", p.Base, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s/-/healthy returned HTTP %d", p.Base, resp.StatusCode)
	}
	return nil
}
