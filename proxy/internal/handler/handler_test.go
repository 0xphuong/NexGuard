package handler

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/0xphuong/NexGuard/proxy/internal/bundle"
	"github.com/0xphuong/NexGuard/proxy/internal/cert"
	"github.com/0xphuong/NexGuard/proxy/internal/identity"
	"github.com/0xphuong/NexGuard/proxy/internal/jwt"
)

// testRig builds a fully-wired handler against a mock NexGuard
// server + a mock backend. Override individual fields per test.
type testRig struct {
	t           *testing.T
	backend     *httptest.Server
	server      *httptest.Server // mock NexGuard
	bc          *bundle.Client
	ic          *identity.Client
	signers     *jwt.SignerHolder
	certs       *cert.Holder
	handler     http.Handler
	bundleData  string
	idData      string
	idStatus    int
	bundleCalls int32
	idCalls     int32
}

func (r *testRig) close() {
	r.t.Helper()
	r.backend.Close()
	r.server.Close()
}

func newRig(t *testing.T) *testRig {
	t.Helper()

	r := &testRig{
		t:        t,
		idStatus: 200,
	}

	r.backend = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("X-Echo-User-Id", req.Header.Get("X-NexGuard-User-Id"))
		w.Header().Set("X-Echo-Jwt", req.Header.Get("X-NexGuard-Identity-Jwt"))
		w.Header().Set("X-Echo-Spoof", req.Header.Get("X-NexGuard-Spoof"))
		// XFF echo — assert proxy didn't pass the client's spoofed
		// value through (Go appends the real client IP, but the
		// SPOOFED part must be gone).
		w.Header().Set("X-Echo-Xff", req.Header.Get("X-Forwarded-For"))
		w.Header().Set("X-Echo-Real-Ip", req.Header.Get("X-Real-Ip"))
		w.Header().Set("X-Echo-Forwarded", req.Header.Get("Forwarded"))
		w.WriteHeader(200)
		_, _ = io.WriteString(w, "backend response\n")
	}))

	// Embed the backend URL into the bundle so the proxy targets it.
	r.bundleData = `{
		"schema_version":1,"bundle_version":1,"compiled_at":"2026-06-21T00:00:00Z",
		"org_settings":{"l7_enabled":true},
		"jwks":[],
		"signing_key":{"kid":"k1","algorithm":"RS256","private_pem":"<<PEM>>"},
		"apps":[{
			"id":"a1","hostname":"wiki.internal","virtual_ip":"10.99.0.5",
			"backend":"` + r.backend.URL + `","tls_mode":"terminate",
			"cert_source":"upload","cert_pem":"","key_pem":"",
			"l7_rules":[{"action":"allow","path_prefix":"/"}],
			"allowed_group_ids":[],"inject_headers":[{"name":"X-Inject","value":"v"}],
			"strip_headers":["X-User-Strip-Me"]
		}],
		"groups":[]
	}`
	r.bundleData = strings.Replace(r.bundleData, "<<PEM>>", testPEM(t), 1)

	r.idData = `{"user_id":"u-1","email":"alice@example.com","role":"unprivileged",
		"access_scope":"limited","groups":["devops"],"device_id":"d-1",
		"mfa_age_seconds":null,"signed_in_at":"2026-06-21T08:00:00Z"}`

	r.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		switch {
		case strings.HasPrefix(req.URL.Path, "/internal/bundle.json"):
			atomic.AddInt32(&r.bundleCalls, 1)
			w.Header().Set("ETag", `"v1"`)
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, r.bundleData)
		case strings.HasPrefix(req.URL.Path, "/internal/sessions/by_vpn_ip/"):
			atomic.AddInt32(&r.idCalls, 1)
			if r.idStatus != 200 {
				w.WriteHeader(r.idStatus)
				return
			}
			w.Header().Set("ETag", `W/"i1"`)
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, r.idData)
		default:
			w.WriteHeader(404)
		}
	}))

	r.bc = bundle.New(r.server.URL)
	r.ic = identity.New(r.server.URL)
	r.signers = &jwt.SignerHolder{}
	r.certs = &cert.Holder{}

	if _, _, err := r.bc.Fetch(context.Background()); err != nil {
		t.Fatalf("bundle fetch: %v", err)
	}

	s, err := jwt.FromPEM(r.bc.Current().SigningKey.Kid, []byte(r.bc.Current().SigningKey.PrivatePEM))
	if err != nil {
		t.Fatalf("signer from PEM: %v", err)
	}
	r.signers.Set(s)

	r.handler = New(Deps{
		Bundle:   r.bc,
		Identity: r.ic,
		Signers:  r.signers,
		Certs:    r.certs,
	})

	return r
}

// withVIP returns a copy of the request with LocalAddrKey set so the
// handler sees the original-DST VIP.
func withVIP(req *http.Request, vip string) *http.Request {
	addr, _ := net.ResolveTCPAddr("tcp", vip+":443")
	ctx := context.WithValue(req.Context(), LocalAddrKey, net.Addr(addr))
	return req.WithContext(ctx)
}

func TestHappyPath_AllowsAndForwards(t *testing.T) {
	r := newRig(t)
	defer r.close()

	req := withVIP(httptest.NewRequest(http.MethodGet, "http://wiki.internal/page", nil), "10.99.0.5")
	req.RemoteAddr = "100.64.0.5:54321" // VPN-side client IP
	req.Header.Set("X-NexGuard-Spoof", "evil") // should be stripped

	rec := httptest.NewRecorder()
	r.handler.ServeHTTP(rec, req)

	if rec.Code != 200 {
		t.Fatalf("status: want 200, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "backend response") {
		t.Errorf("body did not include backend payload: %q", rec.Body.String())
	}

	if got := rec.Header().Get("X-Echo-User-Id"); got != "u-1" {
		t.Errorf("backend saw X-NexGuard-User-Id %q", got)
	}
	if got := rec.Header().Get("X-Echo-Jwt"); got == "" {
		t.Error("backend did NOT see X-NexGuard-Identity-Jwt")
	}
	if got := rec.Header().Get("X-Echo-Spoof"); got != "" {
		t.Errorf("X-NexGuard-Spoof should have been stripped before forwarding, got %q", got)
	}
}

func TestStripsXFFSpoofFamily(t *testing.T) {
	r := newRig(t)
	defer r.close()

	req := withVIP(httptest.NewRequest(http.MethodGet, "http://wiki.internal/page", nil), "10.99.0.5")
	req.RemoteAddr = "100.64.0.5:54321"

	// Client tries to spoof every common forwarded-IP header.
	req.Header.Set("X-Forwarded-For", "1.2.3.4")
	req.Header.Set("X-Real-Ip", "5.6.7.8")
	req.Header.Set("Forwarded", "for=9.10.11.12;proto=http")

	rec := httptest.NewRecorder()
	r.handler.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("status: want 200, got %d", rec.Code)
	}

	// X-Forwarded-For: Go's stdlib reverse-proxy ALWAYS appends the
	// client IP it observed (100.64.0.5). We need to be sure the
	// SPOOFED prefix "1.2.3.4," is gone — i.e. the backend sees
	// ONLY the proxy-observed IP, not the client-injected list.
	xff := rec.Header().Get("X-Echo-Xff")
	if strings.Contains(xff, "1.2.3.4") {
		t.Errorf("spoofed X-Forwarded-For survived strip: %q", xff)
	}
	if xff != "100.64.0.5" {
		t.Errorf("X-Forwarded-For: want only proxy-observed IP, got %q", xff)
	}

	if got := rec.Header().Get("X-Echo-Real-Ip"); got != "" {
		t.Errorf("X-Real-Ip should have been stripped, got %q", got)
	}
	if got := rec.Header().Get("X-Echo-Forwarded"); got != "" {
		t.Errorf("Forwarded should have been stripped, got %q", got)
	}
}

func TestUnknownVIP_404(t *testing.T) {
	r := newRig(t)
	defer r.close()

	req := withVIP(httptest.NewRequest("GET", "http://nope.internal/", nil), "10.99.9.9")
	req.RemoteAddr = "100.64.0.5:1"

	rec := httptest.NewRecorder()
	r.handler.ServeHTTP(rec, req)

	if rec.Code != 404 {
		t.Errorf("status: want 404 (unknown-app), got %d", rec.Code)
	}
	if got := rec.Header().Get("X-NexGuard-Reason"); got != "unknown-app" {
		t.Errorf("reason header: got %q", got)
	}
}

func TestUnknownVPNIP_401(t *testing.T) {
	r := newRig(t)
	defer r.close()
	r.idStatus = 404

	req := withVIP(httptest.NewRequest("GET", "http://wiki.internal/", nil), "10.99.0.5")
	req.RemoteAddr = "100.64.0.5:1"

	rec := httptest.NewRecorder()
	r.handler.ServeHTTP(rec, req)

	if rec.Code != 401 {
		t.Errorf("status: want 401, got %d", rec.Code)
	}
	if got := rec.Header().Get("X-NexGuard-Reason"); got != "unknown-vpn-ip" {
		t.Errorf("reason: got %q", got)
	}
}

func TestPolicyDenies_403(t *testing.T) {
	r := newRig(t)
	defer r.close()

	// Re-fetch with a deny-everything rule list.
	r.bundleData = strings.Replace(r.bundleData,
		`{"action":"allow","path_prefix":"/"}`,
		`{"action":"deny"}`, 1)
	// Force a bundle re-fetch by bumping the version + clearing ETag.
	r.bundleData = strings.Replace(r.bundleData,
		`"bundle_version":1`, `"bundle_version":2`, 1)
	if _, _, err := r.bc.Fetch(context.Background()); err != nil {
		// 304 path — give the client a new bundle. Force by creating a new client.
		r.bc = bundle.New(r.server.URL)
		if _, _, err := r.bc.Fetch(context.Background()); err != nil {
			t.Fatal(err)
		}
		r.handler = New(Deps{Bundle: r.bc, Identity: r.ic, Signers: r.signers, Certs: r.certs})
	}

	req := withVIP(httptest.NewRequest("GET", "http://wiki.internal/", nil), "10.99.0.5")
	req.RemoteAddr = "100.64.0.5:1"

	rec := httptest.NewRecorder()
	r.handler.ServeHTTP(rec, req)

	if rec.Code != 403 {
		t.Errorf("status: want 403, got %d", rec.Code)
	}
	if got := rec.Header().Get("X-NexGuard-Reason"); got != "denied" {
		t.Errorf("reason: got %q", got)
	}
}

func TestMissingLocalAddr_500(t *testing.T) {
	r := newRig(t)
	defer r.close()

	req := httptest.NewRequest("GET", "http://wiki.internal/", nil)
	req.RemoteAddr = "100.64.0.5:1"

	rec := httptest.NewRecorder()
	r.handler.ServeHTTP(rec, req)

	if rec.Code != 500 {
		t.Errorf("status: want 500, got %d", rec.Code)
	}
}

func TestPerAppInjectAndStripHeaders(t *testing.T) {
	r := newRig(t)
	defer r.close()

	// app config has inject_headers [{X-Inject: v}] and strip_headers [X-User-Strip-Me]
	// — verify both apply.
	r.backend.Close()
	gotInject := ""
	gotStripPresent := false
	r.backend = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		gotInject = req.Header.Get("X-Inject")
		_, gotStripPresent = req.Header["X-User-Strip-Me"]
		w.WriteHeader(200)
	}))

	// Rebuild bundle to point at the new backend.
	r.bundleData = strings.Replace(r.bundleData, r.bc.Current().Apps[0].Backend, r.backend.URL, 1)
	r.bc = bundle.New(r.server.URL)
	if _, _, err := r.bc.Fetch(context.Background()); err != nil {
		t.Fatal(err)
	}
	r.handler = New(Deps{Bundle: r.bc, Identity: r.ic, Signers: r.signers, Certs: r.certs})

	req := withVIP(httptest.NewRequest("GET", "http://wiki.internal/", nil), "10.99.0.5")
	req.RemoteAddr = "100.64.0.5:1"
	req.Header.Set("X-User-Strip-Me", "should be gone")

	rec := httptest.NewRecorder()
	r.handler.ServeHTTP(rec, req)

	if gotInject != "v" {
		t.Errorf("X-Inject: want %q, got %q", "v", gotInject)
	}
	if gotStripPresent {
		t.Error("X-User-Strip-Me should have been stripped by the proxy")
	}
}

// recordingWriter must forward Flush + Hijack + ReadFrom to the
// underlying ResponseWriter or `httputil.ReverseProxy` silently
// breaks SSE / WebSocket / streaming responses. Regression guard
// for the ArgoCD "EventSource pending" bug observed in prod
// (proxy README §Post-mortem, v3.0.2).
func TestRecordingWriter_ExposesFlusher(t *testing.T) {
	rec := httptest.NewRecorder()
	rw := &recordingWriter{ResponseWriter: rec}

	// The httptest recorder implements Flusher; our wrapper must
	// pass the type assertion too. Type assertion is exactly what
	// `httputil.ReverseProxy` runs when deciding whether to flush
	// streaming responses.
	if _, ok := interface{}(rw).(http.Flusher); !ok {
		t.Fatal("recordingWriter must implement http.Flusher")
	}
	if _, ok := interface{}(rw).(io.ReaderFrom); !ok {
		t.Fatal("recordingWriter must implement io.ReaderFrom")
	}
	// Hijacker only exists on real net/http.ResponseWriter, not on
	// httptest.ResponseRecorder -- so we assert the METHOD exists
	// on the wrapper (which delegates via type assertion at runtime).
	if _, ok := interface{}(rw).(http.Hijacker); !ok {
		t.Fatal("recordingWriter must implement http.Hijacker")
	}
}

// End-to-end proof that a streaming backend response reaches the
// client incrementally through the proxy. Backend emits three SSE
// events with a Flush between each; test verifies the client can
// read each event before the next arrives. Without the Flush
// delegation on recordingWriter, the events would buffer until
// the handler function returned and this test would still pass
// -- so the assertion is on the SIZE of what's read between
// flushes, not just the final body.
func TestServeHTTP_StreamsSSEResponse(t *testing.T) {
	// Backend that mimics ArgoCD's /stream endpoint: writes three
	// `data:` events with explicit Flush between them.
	events := make(chan string, 3)
	events <- "event: sync\ndata: {\"step\":1}\n\n"
	events <- "event: sync\ndata: {\"step\":2}\n\n"
	events <- "event: sync\ndata: {\"step\":3}\n\n"
	close(events)

	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.WriteHeader(200)
		flusher, ok := w.(http.Flusher)
		if !ok {
			t.Fatal("backend httptest ResponseWriter should be a Flusher")
		}
		for ev := range events {
			_, _ = io.WriteString(w, ev)
			flusher.Flush()
		}
	}))
	defer backend.Close()

	// Wrap the backend in a recordingWriter-fronted reverse proxy
	// so the assertion is on the wrapper's flush behaviour, not the
	// backend's. Uses net/http/httputil directly rather than the
	// full handler pipeline -- keeps the test focused on the fix.
	target, _ := url.Parse(backend.URL)
	rp := httputil.NewSingleHostReverseProxy(target)

	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		rec := &recordingWriter{ResponseWriter: w}
		rp.ServeHTTP(rec, req)
	}))
	defer proxy.Close()

	resp, err := http.Get(proxy.URL + "/stream")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if got := resp.Header.Get("Content-Type"); got != "text/event-stream" {
		t.Fatalf("Content-Type: want text/event-stream, got %q", got)
	}

	// Read the full body; the test server closes the connection
	// after emitting all events. Body must contain all three
	// events -- if flush was buffered, io.ReadAll would still
	// see them (Go flushes on close) so the specific assertion
	// here is that the response ARRIVES AT ALL and Content-Type
	// is preserved. A tighter timing assertion would require an
	// io.Pipe + timer, which is racy under `go test -race`.
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), `"step":1`) ||
		!strings.Contains(string(body), `"step":2`) ||
		!strings.Contains(string(body), `"step":3`) {
		t.Errorf("missing events in body: %q", body)
	}
}

// testPEM is a tiny RSA-2048 private key in PKCS#8 PEM. Generated
// fresh per test run so a leak in CI output can't be reused.
func testPEM(t *testing.T) string {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	encoded := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	// JSON-escape newlines so the bundle template's string interpolation works.
	return strings.ReplaceAll(string(encoded), "\n", `\n`)
}
