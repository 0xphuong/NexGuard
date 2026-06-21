// Package observability owns the L7 proxy's structured logging,
// Prometheus metrics, and /healthz + /readyz endpoints (D-13, D-14,
// D-15).
//
// One process exposes ALL of these on a single second port (default
// :9090) — separate from the public TLS listener so an operator
// scraping metrics never accidentally hits a user-facing port and
// vice versa.
package observability

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Metrics is the per-process Prometheus collector set. Pass a single
// shared instance into the handler so every request increments the
// same counters.
type Metrics struct {
	requestsTotal     *prometheus.CounterVec
	requestDuration   *prometheus.HistogramVec
	bundleVersion     prometheus.Gauge
	bundleAgeSeconds  prometheus.Gauge
	identityCacheSize prometheus.Gauge
}

// NewMetrics constructs a Metrics bound to a fresh registry. The
// caller passes the registry to promhttp.HandlerFor (via the Handler
// helper below) to expose `/metrics`.
func NewMetrics() (*Metrics, *prometheus.Registry) {
	reg := prometheus.NewRegistry()

	m := &Metrics{
		requestsTotal: prometheus.NewCounterVec(
			prometheus.CounterOpts{
				Namespace: "nexguard_proxy",
				Name:      "requests_total",
				Help:      "Total proxied requests, labeled by decision and HTTP status family.",
			},
			[]string{"decision", "status_family"},
		),
		requestDuration: prometheus.NewHistogramVec(
			prometheus.HistogramOpts{
				Namespace: "nexguard_proxy",
				Name:      "request_duration_seconds",
				Help:      "Wall-clock duration of proxied requests, end-to-end including the backend hop.",
				// Default buckets aren't right for an L7 proxy where
				// p50 lives around a few ms; spread out from 1 ms.
				Buckets: []float64{0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
			},
			[]string{"decision"},
		),
		bundleVersion: prometheus.NewGauge(prometheus.GaugeOpts{
			Namespace: "nexguard_proxy",
			Name:      "bundle_version",
			Help:      "Currently-loaded bundle version (monotonic integer from the server).",
		}),
		bundleAgeSeconds: prometheus.NewGauge(prometheus.GaugeOpts{
			Namespace: "nexguard_proxy",
			Name:      "bundle_age_seconds",
			Help:      "Seconds since the last successful bundle fetch.",
		}),
		identityCacheSize: prometheus.NewGauge(prometheus.GaugeOpts{
			Namespace: "nexguard_proxy",
			Name:      "identity_cache_size",
			Help:      "Number of identity entries currently in the per-VPN-IP TTL cache.",
		}),
	}

	reg.MustRegister(
		m.requestsTotal, m.requestDuration,
		m.bundleVersion, m.bundleAgeSeconds, m.identityCacheSize,
	)

	return m, reg
}

// RecordRequest is called once per request — typically deferred in
// the handler — capturing the decision label and elapsed seconds.
// `decision` is one of allow|deny|error; `status` is the HTTP status
// code we wrote.
func (m *Metrics) RecordRequest(decision string, status int, seconds float64) {
	if m == nil {
		return
	}
	m.requestsTotal.WithLabelValues(decision, statusFamily(status)).Inc()
	m.requestDuration.WithLabelValues(decision).Observe(seconds)
}

// SetBundleVersion exposes the current bundle version as a gauge so
// dashboards can alert on stale bundles or version mismatches across
// multiple proxy replicas.
func (m *Metrics) SetBundleVersion(v int) {
	if m == nil {
		return
	}
	m.bundleVersion.Set(float64(v))
}

// SetBundleAgeSeconds is updated by the bundle poller every tick.
func (m *Metrics) SetBundleAgeSeconds(s float64) {
	if m == nil {
		return
	}
	m.bundleAgeSeconds.Set(s)
}

// SetIdentityCacheSize is updated periodically by the main loop.
func (m *Metrics) SetIdentityCacheSize(n int) {
	if m == nil {
		return
	}
	m.identityCacheSize.Set(float64(n))
}

// Handler returns the /metrics HTTP handler bound to the supplied
// registry. Use with `http.Handle("/metrics", obs.Handler(reg))`.
func Handler(reg *prometheus.Registry) http.Handler {
	return promhttp.HandlerFor(reg, promhttp.HandlerOpts{
		EnableOpenMetrics: true,
	})
}

func statusFamily(code int) string {
	switch {
	case code >= 500:
		return "5xx"
	case code >= 400:
		return "4xx"
	case code >= 300:
		return "3xx"
	case code >= 200:
		return "2xx"
	default:
		return "other"
	}
}
