package observability

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
)

func TestRecordRequest_IncrementsExpectedSeries(t *testing.T) {
	m, reg := NewMetrics()
	m.RecordRequest("allow", 200, 0.012)
	m.RecordRequest("allow", 200, 0.015)
	m.RecordRequest("deny", 403, 0.001)
	m.RecordRequest("error", 502, 0.002)

	body := scrape(t, reg)

	mustContain(t, body, `nexguard_proxy_requests_total{decision="allow",status_family="2xx"} 2`)
	mustContain(t, body, `nexguard_proxy_requests_total{decision="deny",status_family="4xx"} 1`)
	mustContain(t, body, `nexguard_proxy_requests_total{decision="error",status_family="5xx"} 1`)
	mustContain(t, body, `nexguard_proxy_request_duration_seconds_count{decision="allow"} 2`)
}

func TestStatusFamily(t *testing.T) {
	cases := map[int]string{
		200: "2xx", 201: "2xx", 299: "2xx",
		301: "3xx", 304: "3xx",
		400: "4xx", 404: "4xx", 499: "4xx",
		500: "5xx", 502: "5xx", 599: "5xx",
		0:   "other", 199: "other",
	}
	for code, want := range cases {
		if got := statusFamily(code); got != want {
			t.Errorf("statusFamily(%d): want %q, got %q", code, want, got)
		}
	}
}

func TestNilMetrics_SafeNoOp(t *testing.T) {
	var m *Metrics
	// Each method must accept a nil receiver — useful for tests +
	// dev builds that don't wire metrics.
	m.RecordRequest("allow", 200, 0)
	m.SetBundleVersion(1)
	m.SetBundleAgeSeconds(2)
	m.SetIdentityCacheSize(3)
}

func TestSetBundleVersionAppearsInScrape(t *testing.T) {
	m, reg := NewMetrics()
	m.SetBundleVersion(42)
	mustContain(t, scrape(t, reg), "nexguard_proxy_bundle_version 42")
}

// scrape exercises the /metrics handler against the registry,
// returning the response body as a string.
func scrape(t *testing.T, reg *prometheus.Registry) string {
	t.Helper()
	srv := httptest.NewServer(Handler(reg))
	defer srv.Close()

	resp, err := http.Get(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return string(b)
}

func mustContain(t *testing.T, body, needle string) {
	t.Helper()
	if !strings.Contains(body, needle) {
		t.Errorf("metrics scrape missing %q\n--- body ---\n%s", needle, body)
	}
}
