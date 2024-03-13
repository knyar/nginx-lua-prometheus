// This is a simple integration test for nginx-lua-prometheus.
package main

import (
	"context"
	"flag"
	"fmt"
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

const metricsURL = "http://localhost:18000/metrics"

type testRunner struct {
	client *http.Client
	tests  []testFunc
	checks []checkFunc
}

type testFunc func() error
type checkFunc func(*testData) error

type testData struct {
	metrics map[string]*dto.MetricFamily
}

func main() {
	flag.Parse()

	// Use a custom http client with a lower idle connection timeout and a request timeout.
	client := &http.Client{
		Timeout:   500 * time.Millisecond,
		Transport: &http.Transport{IdleConnTimeout: 400 * time.Millisecond},
	}

	// Wait for nginx to start.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := waitFor(ctx, client, metricsURL); err != nil {
		log.Fatal(err)
	}

	// Register tests.
	t := &testRunner{client: client}
	registerBasic(t)

	// Run tests.
	var wg sync.WaitGroup
	for _, tt := range t.tests {
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
	resp, err := client.Get(metricsURL)
	if err != nil {
		log.Fatalf("Could not collect metrics: %v", err)
	}
	defer resp.Body.Close()

	// Parse metrics.
	var parser expfmt.TextParser
	res := &testData{}
	res.metrics, err = parser.TextToMetricFamilies(resp.Body)
	if err != nil {
		log.Fatalf("Could not parse metrics: %v", err)
	}

	// Run test checks.
	for _, ch := range t.checks {
		if err := ch(res); err != nil {
			log.Fatal(err)
		}
	}

	log.Print("All ok")
}

func waitFor(ctx context.Context, c *http.Client, url string) error {
	log.Printf("Waiting for %s...", url)
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return fmt.Errorf("creating request for %s: %v", url, err)
	}
	for {
		resp, err := c.Do(req)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				return nil
			}
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		time.Sleep(100 * time.Millisecond)
	}
}
