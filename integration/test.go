// This is a simple integration test for nginx-lua-prometheus.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"sync"
	"time"

	dto "github.com/prometheus/client_model/go"
	"github.com/prometheus/common/expfmt"
)

var (
	testDuration = flag.Duration("duration", 10*time.Second, "duration of the test")
)

const healthURL = "http://localhost:18000/health"
const metricsURL = "http://localhost:18000/metrics"

type testRunner struct {
	ctx        context.Context
	client     *http.Client
	tests      []testFunc
	checks     []checkFunc
	healthURLs []string
}

type testFunc func() error
type checkFunc func(*testData) error

type testData struct {
	metrics map[string]*dto.MetricFamily
}

func main() {
	flag.Parse()

	// Tests are expected to manage their duration themselves based on testDuration.
	// Context timeout is longer than test duration to allow tests to complete
	// without timing out.
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration((*testDuration).Nanoseconds())*2)
	defer cancel()
	tr := &testRunner{
		// Use a custom http client with a lower idle connection timeout and a request timeout.
		client: &http.Client{
			Timeout: 500 * time.Millisecond,
			Transport: &http.Transport{
				IdleConnTimeout: 400 * time.Millisecond,
				MaxIdleConns:    100,
				MaxConnsPerHost: 100,
			},
		},
		ctx:        ctx,
		healthURLs: []string{healthURL},
	}

	// Register tests.
	registerBasicTest(tr)
	registerResetTest(tr)

	// Wait for all nginx servers to come up.
	for _, url := range tr.healthURLs {
		if err := tr.waitFor(url, 5*time.Second); err != nil {
			log.Fatal(err)
		}
	}

	// Run tests.
	var wg sync.WaitGroup
	for _, tt := range tr.tests {
		wg.Add(1)
		go func(tt testFunc) {
			if err := tt(); err != nil {
				log.Fatal(err)
			}
			wg.Done()
		}(tt)
	}
	wg.Wait()

	// Sleep for 500ms before collecting metrics. This is to ensure that all HTTP connections
	// to nginx get closed, and to allow for some eventual consistency in nginx-lua-prometheus.
	time.Sleep(500 * time.Millisecond)

	// Collect metrics.
	res := &testData{
		metrics: tr.mustGetMetrics(context.Background()),
	}

	// Run test checks.
	for _, ch := range tr.checks {
		if err := ch(res); err != nil {
			log.Fatal(err)
		}
	}

	log.Print("All ok")
}

func (tr *testRunner) mustGetMetrics(ctx context.Context) map[string]*dto.MetricFamily {
	var res map[string]*dto.MetricFamily
	tr.mustGetContext(ctx, metricsURL, func(r *http.Response) error {
		if r.StatusCode != 200 {
			return fmt.Errorf("expected response 200 got %v", r)
		}
		var parser expfmt.TextParser
		var err error
		res, err = parser.TextToMetricFamilies(r.Body)
		return err
	})
	return res
}

func (tr *testRunner) getContext(ctx context.Context, url string, cb func(*http.Response) error) error {
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return fmt.Errorf("creating request for %s: %v", url, err)
	}
	resp, err := tr.client.Do(req)
	if err != nil {
		return fmt.Errorf("could not fetch URL %s: %v", url, err)
	}
	defer resp.Body.Close()
	if cb != nil {
		return cb(resp)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("could not read HTTP response for %s: %v", url, err)
	}
	if resp.StatusCode != 200 || string(body) != "ok\n" {
		return fmt.Errorf("unexpected response %q from %s; expected 'ok'", string(body), url)
	}
	return nil
}

func (tr *testRunner) mustGetContext(ctx context.Context, url string, cb func(*http.Response) error) {
	if err := tr.getContext(ctx, url, cb); err != nil {
		log.Fatal(err)
	}
}

func (tr *testRunner) get(url string) error {
	return tr.getContext(tr.ctx, url, nil)
}

func (tr *testRunner) mustGet(url string) {
	if err := tr.get(url); err != nil {
		log.Fatal(err)
	}
}

func (tr *testRunner) waitFor(url string, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(tr.ctx, timeout)
	defer cancel()
	log.Printf("Waiting for %s for %v...", url, timeout)
	for {
		err := tr.getContext(ctx, url, nil)
		if err == nil {
			return nil
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		time.Sleep(100 * time.Millisecond)
	}
}
