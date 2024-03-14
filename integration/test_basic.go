// This is a simple integration test for nginx-lua-prometheus.
package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"math/rand"
	"net/http"
	"sync"
	"time"

	"github.com/golang/protobuf/proto"
	"github.com/google/go-cmp/cmp"
	"github.com/google/go-cmp/cmp/cmpopts"
	"github.com/kr/pretty"
	dto "github.com/prometheus/client_model/go"
)

var (
	concurrency = flag.Int("concurrency", 9, "number of concurrent http clients")
)

type requestType int

const (
	reqFast requestType = iota
	reqSlow
	reqError
)

// There are three separate nginx endpoints:
// - 'fast' simply returns "ok" with a 200 response code;
// - 'slow' waits for 10ms and returns "ok" with a 200 response code;
// - 'error' returns a 500.
var urls = map[requestType]string{
	reqFast:  "http://localhost:18001/fast",
	reqSlow:  "http://localhost:18001/slow",
	reqError: "http://localhost:18001/error",
}

// Expected bucket boundaries. This should match the buckets defined in nginx.conf.
var buckets = []float64{0.08, 0.089991, 0.1, 0.2, 0.75, 1, 1.5, 3.123232001, 5, 15, 120, 350.5, 1500, 75000, 1500000, math.Inf(1)}

// Register a basic test that will send requests to 'fast', 'slow' and 'error'
// endpoints and verify that request counters and latency measurements are
// accurate.
func registerBasicTest(tr *testRunner) {
	tr.healthURLs = append(tr.healthURLs, "http://localhost:18001/health")
	results := make(chan map[requestType]int64, *concurrency)
	tr.tests = append(tr.tests, func() error {
		log.Printf("Running basic test with %d concurrent clients for %v", *concurrency, *testDuration)
		var wg sync.WaitGroup
		for i := 1; i <= *concurrency; i++ {
			wg.Add(1)
			go func() {
				result := make(map[requestType]int64)
				for start := time.Now(); time.Since(start) < *testDuration; {
					t := reqFast
					r := rand.Intn(100)
					if r < 10 {
						// 10% are slow requests
						t = reqSlow
					} else if r < 15 {
						// 5% are errors
						t = reqError
					}
					if t == reqError {
						tr.mustGetContext(tr.ctx, urls[t], func(r *http.Response) error {
							io.Copy(io.Discard, r.Body)
							if r.StatusCode != 500 {
								return fmt.Errorf("expected response 500, got %+v", r)
							}
							return nil
						})
					} else {
						tr.mustGet(urls[t])
					}
					result[t]++
				}
				results <- result
				wg.Done()
			}()
		}
		wg.Wait()
		close(results)
		return nil
	})

	tr.checks = append(tr.checks, func(r *testData) error {
		mfs := r.metrics
		var fast, slow, errors int64
		for r := range results {
			fast += r[reqFast]
			slow += r[reqSlow]
			errors += r[reqError]
		}
		total := fast + slow + errors
		log.Printf("Sent %d requests (%d fast, %d slow, %d errors)", total, fast, slow, errors)

		// We expect all fast requests to take less than 1 second.
		if v := getHistogramSum(mfs, "request_duration_seconds", [][]string{{"path", "/fast"}}); v > 1 {
			return fmt.Errorf("total time to process all fast request is %f; expected <= 1", v)
		}

		minSlowSeconds := float64(slow) * 0.01 // at least 10ms per request
		if v := getHistogramSum(mfs, "request_duration_seconds", [][]string{{"path", "/slow"}}); v <= minSlowSeconds {
			return fmt.Errorf("total time to process all fast request is %f; expected > %f", v, minSlowSeconds)
		}

		expected := []*dto.MetricFamily{
			{
				// There should be no errors reported by the library.
				Name:   proto.String("nginx_metric_errors_total"),
				Help:   proto.String("Number of nginx-lua-prometheus errors"),
				Type:   dto.MetricType_COUNTER.Enum(),
				Metric: []*dto.Metric{{Counter: &dto.Counter{Value: proto.Float64(0)}}},
			},
			{
				Name: proto.String("requests_total"),
				Help: proto.String("Number of HTTP requests"),
				Type: dto.MetricType_COUNTER.Enum(),
				Metric: []*dto.Metric{
					{Label: []*dto.LabelPair{
						{Name: proto.String("host"), Value: proto.String("basic_test")},
						{Name: proto.String("path"), Value: proto.String("/fast")},
						{Name: proto.String("status"), Value: proto.String("200")},
					}, Counter: &dto.Counter{Value: proto.Float64(float64(fast))}},
					{Label: []*dto.LabelPair{
						{Name: proto.String("host"), Value: proto.String("basic_test")},
						{Name: proto.String("path"), Value: proto.String("/slow")},
						{Name: proto.String("status"), Value: proto.String("200")},
					}, Counter: &dto.Counter{Value: proto.Float64(float64(slow))}},
					{Label: []*dto.LabelPair{
						{Name: proto.String("host"), Value: proto.String("basic_test")},
						{Name: proto.String("path"), Value: proto.String("/error")},
						{Name: proto.String("status"), Value: proto.String("500")},
					}, Counter: &dto.Counter{Value: proto.Float64(float64(errors))}},
				},
			},
			{
				// After all tests are complete there should only be a single HTTP
				// connection, which should be in 'writing' state (the connection
				// used by nginx to return metric values).
				Name: proto.String("connections"),
				Help: proto.String("Number of HTTP connections"),
				Type: dto.MetricType_GAUGE.Enum(),
				Metric: []*dto.Metric{
					{Label: []*dto.LabelPair{
						{Name: proto.String("state"), Value: proto.String("reading")},
					}, Gauge: &dto.Gauge{Value: proto.Float64(float64(0))}},
					{Label: []*dto.LabelPair{
						{Name: proto.String("state"), Value: proto.String("waiting")},
					}, Gauge: &dto.Gauge{Value: proto.Float64(float64(0))}},
					{Label: []*dto.LabelPair{
						{Name: proto.String("state"), Value: proto.String("writing")},
					}, Gauge: &dto.Gauge{Value: proto.Float64(float64(1))}},
				},
			},
		}

		for _, mf := range expected {
			if err := hasMetricFamily(mfs, mf); err != nil {
				return err
			}
		}

		return checkBucketBoundaries(mfs, "request_duration_seconds")
	})
}

// getHistogramSum returns the 'sum' value for a given histogram metric.
func getHistogramSum(mfs map[string]*dto.MetricFamily, metric string, labels [][]string) float64 {
	var lps []*dto.LabelPair
	for _, lp := range labels {
		lps = append(lps, &dto.LabelPair{Name: proto.String(lp[0]), Value: proto.String(lp[1])})
	}

	for _, mf := range mfs {
		if *mf.Name == metric {
			for _, m := range mf.Metric {
				if cmp.Equal(m.Label, lps) {
					return *m.Histogram.SampleSum
				}
			}
		}
	}
	log.Fatalf("Metric %s with labels %v not found in %v", metric, lps, mfs)
	return 0
}

// hasMetricFamily verifies that a given MetricFamily exists in a passed list of
// metric families.
func hasMetricFamily(mfs map[string]*dto.MetricFamily, want *dto.MetricFamily) error {
	sortFn := func(x, y interface{}) bool { return pretty.Sprint(x) < pretty.Sprint(y) }
	for _, mf := range mfs {
		if mf.GetName() == want.GetName() {
			if diff := cmp.Diff(want, mf, cmpopts.SortSlices(sortFn)); diff != "" {
				log.Printf("Want: %+v", want)
				log.Printf("Got:  %+v", mf)
				return fmt.Errorf("unexpected metric family %v (-want +got):\n%s", mf.Name, diff)
			}
			return nil
		}
	}
	return fmt.Errorf("metric family %v not found in %v", want, mfs)
}

// checkBucketBoundaries verifies bucket boundary values.
func checkBucketBoundaries(mfs map[string]*dto.MetricFamily, metric string) error {
	matched := false
	for _, mf := range mfs {
		if *mf.Name != metric {
			continue
		}
		matched = true
		for _, m := range mf.Metric {
			if len(m.Histogram.Bucket) != len(buckets) {
				return fmt.Errorf("expected %d buckets but got %d: %v", len(buckets), len(m.Histogram.Bucket), m.Histogram.Bucket)
			}
			for idx, b := range m.Histogram.Bucket {
				tolerance := 0.00001
				if diff := math.Abs(*b.UpperBound - buckets[idx]); diff > tolerance {
					return fmt.Errorf("unexpected value for bucket #%d; want %f got %f", idx, buckets[idx], *b.UpperBound)
				}
			}
		}
	}

	if !matched {
		return fmt.Errorf("could not find metric %s", metric)
	}

	return nil
}
