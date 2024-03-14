// This is a simple integration test for nginx-lua-prometheus.
package main

import (
	"fmt"
	"log"
	"math/rand"
	"sync"
	"time"

	dto "github.com/prometheus/client_model/go"
)

func registerResetTest(tr *testRunner) {
	tr.healthURLs = append(tr.healthURLs, "http://localhost:18002/health")

	const setURL = "http://localhost:18002/set_gauge"
	const resetURL = "http://localhost:18002/reset_gauge"
	const metricName = "reset_test_gauge"
	tr.tests = append(tr.tests, func() error {
		log.Printf("Running reset test with %d concurrent clients for %v", *concurrency, *testDuration)
		var wg sync.WaitGroup
		var mu sync.RWMutex
		for i := 1; i <= *concurrency; i++ {
			wg.Add(1)
			go func(i int) {
				labelValue := fmt.Sprintf("client%d", i)
				setUrl := func(value int) string {
					return fmt.Sprintf("%s?labelvalue=%s&metricvalue=%d", setURL, labelValue, value)
				}
				// Check that returned metrics contain a value for this worker.
				// If wantValue is 0, it means the metric should not exist at all.
				checkValue := func(mfs map[string]*dto.MetricFamily, wantValue int) {
					for _, mf := range mfs {
						if mf.GetName() != metricName {
							continue
						}
						if wantValue == 0 {
							log.Fatalf("client %d: metric %s exists while it should not; %+v", i, metricName, mf)
						}
						for _, m := range mf.Metric {
							if len(m.Label) != 1 {
								log.Fatalf("client %d: expected metric %s to have 1 label, got %+v", i, metricName, m)
							}
							if m.Label[0].GetValue() != labelValue {
								continue
							}
							if m.GetGauge().GetValue() != float64(wantValue) {
								log.Fatalf("client %d: expected metric %s to have value of %d, got %+v", i, metricName, wantValue, m)
							}
							return
						}
						log.Fatalf("client %d: metric %s does not have label %s while it should; %+v", i, metricName, labelValue, mf)
					}
					if wantValue != 0 {
						log.Fatalf("client %d: metric %s not found in %+v", i, metricName, mfs)
					}
				}
				for start := time.Now(); time.Since(start) < *testDuration; {
					// Call the URL that sets a label value and confirm that it
					// exists in the returned metrics.
					value := 1 + rand.Intn(9000)
					mu.RLock()
					tr.mustGet(setUrl(value))
					metrics := tr.mustGetMetrics(tr.ctx)
					checkValue(metrics, value)
					mu.RUnlock()

					// Occasionally, reset the metric and confirm that it does
					// not get returned. A mutex ensures that no other clients
					// attempt to change or reset the gauge at the same time.
					if rand.Intn(100) < 5 {
						mu.Lock()
						tr.mustGet(resetURL)
						metrics := tr.mustGetMetrics(tr.ctx)
						checkValue(metrics, 0)
						// Wait for slightly longer than sync_interval to ensure that
						// metric reset gets propagated to all workers.
						time.Sleep(105 * time.Millisecond)
						mu.Unlock()
					}
				}
				wg.Done()
			}(i)
		}
		wg.Wait()
		return nil
	})
}
