// This is a simple integration test for nginx-lua-prometheus.
package main

import (
    "encoding/json"
	"flag"
	"fmt"
	"io/ioutil"
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
	"github.com/prometheus/common/expfmt"
)

type LookupSizeInfo struct {
    Counter     int      `json:"metric_counter_dummy"`
    Gauge       int      `json:"metric_gauge_dummy"`
    Histogram   int      `json:"metric_histogram_dummy"`
}

var (
	testDuration = flag.Duration("duration", 10*time.Second, "duration of the test")
	concurrency  = flag.Int("concurrency", 9, "number of concurrent http clients")
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
	reqFast:  "http://localhost:18001/",
	reqSlow:  "http://localhost:18002/",
	reqError: "http://localhost:18001/error",
}

// Verify bucket boundaries. This should match the buckets defined in nginx.conf.
var buckets = []float64{0.08, 0.089991, 0.1, 0.2, 0.75, 1, 1.5, 3.123232001, 5, 15, 120, 350.5, 1500, 75000, 1500000, math.Inf(1)}

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
		if *mf.Name == *want.Name {
			if diff := cmp.Diff(want, mf, cmpopts.SortSlices(sortFn)); diff != "" {
				return fmt.Errorf("Unexpected metric family %v (-want +got):\n%s", mf.Name, diff)
			}
			return nil
		}
	}
	return fmt.Errorf("Metric family %v not found in %v", want, mfs)
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

func get_lookup_size(client *http.Client) *LookupSizeInfo {
    resp, err := client.Get("http://localhost:18003/get_lookup_size")
    if err != nil {
        log.Fatal(err)
    }
    defer resp.Body.Close()
    body, err := ioutil.ReadAll(resp.Body)
    if err != nil {
        log.Fatal(err)
    }
    info := &LookupSizeInfo{}
    if err := json.Unmarshal(body, info); err != nil {
        log.Fatal(err)
    }
    return info
}

func main() {
	flag.Parse()

	// Use a custom http client with a lower idle connection timeout and a request timeout.
	client := &http.Client{
		Timeout:   500 * time.Millisecond,
		Transport: &http.Transport{IdleConnTimeout: 400 * time.Millisecond},
	}

	log.Printf("Starting the test with %d concurrent clients", *concurrency)
	var wg sync.WaitGroup
	results := make(chan map[requestType]int64, *concurrency)
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
				resp, err := client.Get(urls[t])
				if err != nil {
					log.Fatalf("Could not fetch URL %s: %v", urls[t], err)
				}
				body, err := ioutil.ReadAll(resp.Body)
				if err != nil {
					log.Fatalf("Could not read HTTP response for %s: %v", urls[t], err)
				}
				resp.Body.Close()
				if t != reqError && string(body) != "ok\n" {
					log.Fatalf("Unexpected response %q from %s; expected 'ok'", string(body), urls[t])
				}
				result[t]++
			}
			results <- result
			wg.Done()
		}()
	}
	wg.Wait()
	close(results)

	var fast, slow, errors int64
	for r := range results {
		fast += r[reqFast]
		slow += r[reqSlow]
		errors += r[reqError]
	}
	total := fast + slow + errors
	log.Printf("Sent %d requests (%d fast, %d slow, %d errors)", total, fast, slow, errors)

	// Sleep for 500ms before collecting metrics. This is to ensure that all HTTP connections
	// to nginx get closed, and to allow for some eventual consistency in nginx-lua-prometheus.
	time.Sleep(500 * time.Millisecond)

	resp, err := client.Get("http://localhost:18001/metrics")
	if err != nil {
		log.Fatalf("Could not collect metrics: %v", err)
	}
	defer resp.Body.Close()

	var parser expfmt.TextParser
	mfs, err := parser.TextToMetricFamilies(resp.Body)
	if err != nil {
		log.Fatalf("Could not parse metrics: %v", err)
	}

	// We expect all fast requests to take less than 1 second.
	if v := getHistogramSum(mfs, "request_duration_seconds", [][]string{{"host", "fast"}}); v > 1 {
		log.Fatalf("Total time to process all fast request is %f; expected <= 1", v)
	}

	minSlowSeconds := float64(slow) * 0.01 // at least 10ms per request
	if v := getHistogramSum(mfs, "request_duration_seconds", [][]string{{"host", "slow"}}); v <= minSlowSeconds {
		log.Fatalf("Total time to process all fast request is %f; expected > %f", v, minSlowSeconds)
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
					{Name: proto.String("host"), Value: proto.String("fast")},
					{Name: proto.String("status"), Value: proto.String("200")},
				}, Counter: &dto.Counter{Value: proto.Float64(float64(fast))}},
				{Label: []*dto.LabelPair{
					{Name: proto.String("host"), Value: proto.String("slow")},
					{Name: proto.String("status"), Value: proto.String("200")},
				}, Counter: &dto.Counter{Value: proto.Float64(float64(slow))}},
				{Label: []*dto.LabelPair{
					{Name: proto.String("host"), Value: proto.String("fast")},
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
			log.Fatal(err)
		}
	}

	if err := checkBucketBoundaries(mfs, "request_duration_seconds"); err != nil {
		log.Fatal(err)
	}

    // check lookup table if truncated
    info := get_lookup_size(client)
    if info.Counter != 0 || info.Gauge != 0 || info.Histogram != 0 {
        log.Fatal("wrong initial lookup_size")
    }
    for i := 0; i <= 1000; i++ {
        resp, err := client.Get(fmt.Sprintf("http://localhost:18003/update?tag=%d", i))
        if err != nil {
            log.Fatal(err)
        }
        resp.Body.Close()

        if i == 999 {
            info := get_lookup_size(client)
            if info.Counter != 1000 || info.Gauge != 1000 || info.Histogram != 1000 {
                log.Fatalf("metric lookup table not updated: %+v\n", info)
            }
        } else if i == 1000 {
            info := get_lookup_size(client)
            if info.Counter != 1 || info.Gauge != 1 || info.Histogram != 1 {
                log.Fatalf("metric lookup table not truncated: %+v\n", info)
            }
        }
    }

	log.Print("All ok")
}
