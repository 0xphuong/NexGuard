package observability

import (
	"net/http"
	"sync/atomic"
)

// Health is the process readiness probe. /healthz reports liveness
// (process up + responsive); /readyz reports readiness to serve
// real traffic (bundle loaded, signer ready, identity backend
// reachable on last fetch).
//
// Health goroutine-safe via atomic.Bool — the bundle poller flips
// SetReady after first successful fetch + signer/cert load.
type Health struct {
	ready atomic.Bool
}

func NewHealth() *Health { return &Health{} }

func (h *Health) SetReady(v bool) { h.ready.Store(v) }
func (h *Health) IsReady() bool   { return h.ready.Load() }

// Healthz handler: always 200 once the process is running.
// Kubernetes / systemd uses this to decide whether to restart the
// container. Returning anything else means "kill me".
func (h *Health) Healthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	_, _ = w.Write([]byte("ok\n"))
}

// Readyz: 200 only when SetReady(true) has been called. Pre-bundle,
// returns 503 so an upstream LB knows not to send traffic yet.
func (h *Health) Readyz(w http.ResponseWriter, _ *http.Request) {
	if !h.IsReady() {
		http.Error(w, "not ready\n", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "text/plain")
	_, _ = w.Write([]byte("ready\n"))
}
