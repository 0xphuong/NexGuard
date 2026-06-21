// Package integration drives the proxy hot path end-to-end with a
// mock NexGuard server and a mock backend. Skips the
// IP_TRANSPARENT listener (which requires NET_ADMIN) and wires the
// handler directly against the standard net/http stack.
//
// Two goals:
//
//   - D-18: assert the full pipeline (bundle fetch → identity
//     lookup → policy → JWT inject → reverse proxy) does what each
//     unit test claims when composed.
//   - D-19: perf budget — 1 k req/s sustained, p99 < 50 ms on the
//     test machine. Gated by NEXGUARD_PERF=1 so a normal `go test`
//     doesn't run a 30-second loadgen.
package integration_test

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"sort"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/0xphuong/NexGuard/proxy/internal/bundle"
	"github.com/0xphuong/NexGuard/proxy/internal/cert"
	"github.com/0xphuong/NexGuard/proxy/internal/handler"
	"github.com/0xphuong/NexGuard/proxy/internal/identity"
	"github.com/0xphuong/NexGuard/proxy/internal/jwt"
)

// fixture is a fully-wired proxy + mock server + mock backend ready
// for HTTP-level assertions. The cancel function tears all three
// down.
type fixture struct {
	t             *testing.T
	backend       *httptest.Server
	server        *httptest.Server
	proxy         *httptest.Server
	bc            *bundle.Client
	ic            *identity.Client
	signers       *jwt.SignerHolder
	publicKey     *rsa.PublicKey
	backendCalls  int32
	serverCalls   int32
	identityCalls int32
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	f := &fixture{t: t}

	// Mock backend — echoes whatever NexGuard headers the proxy
	// injected, so the test can assert on them.
	f.backend = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&f.backendCalls, 1)
		w.Header().Set("X-Echo-User-Id", r.Header.Get("X-NexGuard-User-Id"))
		w.Header().Set("X-Echo-Email", r.Header.Get("X-NexGuard-User-Email"))
		w.Header().Set("X-Echo-Groups", r.Header.Get("X-NexGuard-Groups"))
		w.Header().Set("X-Echo-Jwt", r.Header.Get("X-NexGuard-Identity-Jwt"))
		w.WriteHeader(200)
		_, _ = io.WriteString(w, "ok\n")
	}))

	// Generate fresh RSA key, mint a bundle pinning the public key
	// in JWKS + private PEM in signing_key.
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	f.publicKey = &key.PublicKey
	privPEM := privatePKCS8PEM(t, key)

	// Server side: emit bundle.json + an identity payload for the
	// fixed test VPN IP "100.64.0.5".
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/internal/bundle.json"):
			atomic.AddInt32(&f.serverCalls, 1)
			w.Header().Set("ETag", `"v1"`)
			w.Header().Set("Content-Type", "application/json")
			_, _ = fmt.Fprintf(w, bundleJSONTemplate, "kid-test-1", privPEM, f.backend.URL)
		case strings.HasPrefix(r.URL.Path, "/internal/sessions/by_vpn_ip/"):
			atomic.AddInt32(&f.identityCalls, 1)
			w.Header().Set("ETag", `W/"u-1"`)
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"user_id":"u-1","email":"alice@example.com",
				"role":"unprivileged","access_scope":"limited",
				"groups":["devops"],"device_id":"d-1",
				"mfa_age_seconds":120,"signed_in_at":"2026-06-21T08:00:00Z"}`)
		default:
			w.WriteHeader(404)
		}
	}))

	// Compose the proxy stack against the mocks.
	f.bc = bundle.New(f.server.URL)
	f.ic = identity.New(f.server.URL)
	f.signers = &jwt.SignerHolder{}
	if _, _, err := f.bc.Fetch(context.Background()); err != nil {
		t.Fatalf("bundle bootstrap: %v", err)
	}
	signer, err := jwt.FromPEM(
		f.bc.Current().SigningKey.Kid,
		[]byte(f.bc.Current().SigningKey.PrivatePEM),
	)
	if err != nil {
		t.Fatalf("signer build: %v", err)
	}
	f.signers.Set(signer)

	// Proxy server: a thin httptest.Server wrapping the handler.
	// We can't use the real IP_TRANSPARENT listener in a unit-style
	// test, so we manually inject LocalAddr (the original-DST VIP)
	// via the request context on every request. The integration
	// suite always targets one VIP — 10.99.0.5 — matching the
	// bundle.
	h := handler.New(handler.Deps{
		Bundle:   f.bc,
		Identity: f.ic,
		Signers:  f.signers,
		Certs:    &cert.Holder{}, // unused on the HTTP path
	})
	vipAddr := mustTCPAddr(t, "10.99.0.5:443")
	f.proxy = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx := context.WithValue(r.Context(), handler.LocalAddrKey, vipAddr)
		h.ServeHTTP(w, r.WithContext(ctx))
	}))

	t.Cleanup(func() {
		f.proxy.Close()
		f.server.Close()
		f.backend.Close()
	})

	return f
}

// bundleJSONTemplate has placeholders for kid, private_pem, backend.
// Note: private_pem contains literal `\n` chars (JSON-escaped) so
// keep this in sync with the formatter (use %s with privatePKCS8PEM
// output that's already JSON-escaped).
const bundleJSONTemplate = `{
  "schema_version": 1,
  "bundle_version": 1,
  "compiled_at": "2026-06-21T08:00:00Z",
  "org_settings": {"l7_enabled": true},
  "jwks": [],
  "signing_key": {"kid": "%s", "algorithm": "RS256", "private_pem": "%s"},
  "apps": [{
    "id": "app-1",
    "hostname": "wiki.internal",
    "virtual_ip": "10.99.0.5",
    "backend": "%s",
    "tls_mode": "terminate",
    "cert_source": "upload",
    "cert_pem": "",
    "key_pem": "",
    "l7_rules": [
      {"action":"allow","method":["GET","POST"],"path_prefix":"/api/"},
      {"action":"deny"}
    ],
    "allowed_group_ids": [],
    "inject_headers": [],
    "strip_headers": []
  }],
  "groups": []
}`

func privatePKCS8PEM(t *testing.T, key *rsa.PrivateKey) string {
	t.Helper()
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	encoded := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	return strings.ReplaceAll(string(encoded), "\n", `\n`)
}

func mustTCPAddr(t *testing.T, hp string) net.Addr {
	t.Helper()
	addr, err := net.ResolveTCPAddr("tcp", hp)
	if err != nil {
		t.Fatalf("resolve %q: %v", hp, err)
	}
	return addr
}

// ──────────────────────────────────────────────────────────────
// D-18 — integration tests
// ──────────────────────────────────────────────────────────────

func TestIntegration_HappyPath_BackendSeesJWT(t *testing.T) {
	f := newFixture(t)

	req := mustNewRequest(t, "GET", f.proxy.URL+"/api/widgets", nil)
	req.RemoteAddr = "100.64.0.5:54321"

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("proxy GET: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		t.Fatalf("status: want 200, got %d", resp.StatusCode)
	}

	// Backend MUST have been hit with our identity headers.
	if atomic.LoadInt32(&f.backendCalls) != 1 {
		t.Errorf("backend call count: want 1, got %d", f.backendCalls)
	}
	gotJWT := resp.Header.Get("X-Echo-Jwt")
	if gotJWT == "" {
		t.Error("backend did not see X-NexGuard-Identity-Jwt header")
	}

	// JWT must be a well-formed compact JWS (3 parts).
	parts := strings.Split(gotJWT, ".")
	if len(parts) != 3 {
		t.Fatalf("malformed JWT: %q", gotJWT)
	}

	// Decode + verify against the public key the fixture generated.
	verifyJWT(t, gotJWT, f.publicKey)
}

func TestIntegration_PolicyDeny_BackendNotHit(t *testing.T) {
	f := newFixture(t)

	// Path /admin/ doesn't match the allow rule (path_prefix /api/)
	// so the default-deny catch-all fires.
	req := mustNewRequest(t, "GET", f.proxy.URL+"/admin/", nil)
	req.RemoteAddr = "100.64.0.5:54321"

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("proxy GET: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 403 {
		t.Errorf("status: want 403, got %d", resp.StatusCode)
	}
	if got := resp.Header.Get("X-NexGuard-Reason"); got != "denied" {
		t.Errorf("reason: got %q", got)
	}
	if atomic.LoadInt32(&f.backendCalls) != 0 {
		t.Errorf("backend should NOT have been hit on deny; got %d calls", f.backendCalls)
	}
}

func TestIntegration_IdentityCache_BurstAfterWarmup(t *testing.T) {
	f := newFixture(t)

	// Warmup request — populates the cache. We don't have
	// singleflight on cold misses (each concurrent caller would
	// hit the server until the first stores), so we test the
	// cache by warming first and then asserting that a burst of
	// 20 follow-ups hits the server ZERO additional times.
	warm := mustNewRequest(t, "GET", f.proxy.URL+"/api/x", nil)
	warm.RemoteAddr = "100.64.0.5:54321"
	resp, err := http.DefaultClient.Do(warm)
	if err != nil {
		t.Fatalf("warmup: %v", err)
	}
	resp.Body.Close()

	callsAfterWarmup := atomic.LoadInt32(&f.identityCalls)
	if callsAfterWarmup != 1 {
		t.Fatalf("warmup should hit server once; got %d", callsAfterWarmup)
	}

	const N = 20
	done := make(chan int, N)
	for i := 0; i < N; i++ {
		go func() {
			req := mustNewRequest(t, "GET", f.proxy.URL+"/api/x", nil)
			req.RemoteAddr = "100.64.0.5:54321"
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				done <- -1
				return
			}
			resp.Body.Close()
			done <- resp.StatusCode
		}()
	}
	for i := 0; i < N; i++ {
		if got := <-done; got != 200 {
			t.Errorf("request %d status: %d", i, got)
		}
	}

	// All 20 follow-ups must be served from the cache — server
	// still at the warmup's 1 call.
	if got := atomic.LoadInt32(&f.identityCalls); got != callsAfterWarmup {
		t.Errorf("identity server hit during cached burst: was %d, now %d", callsAfterWarmup, got)
	}
}

// ──────────────────────────────────────────────────────────────
// D-19 — perf test (gated by NEXGUARD_PERF=1)
// ──────────────────────────────────────────────────────────────

func TestPerf_ThroughputLatency(t *testing.T) {
	if os.Getenv("NEXGUARD_PERF") != "1" {
		t.Skip("set NEXGUARD_PERF=1 to run the perf budget assertion")
	}
	const (
		duration   = 10 * time.Second
		concurrent = 32
	)
	f := newFixture(t)

	stop := make(chan struct{})
	var requests, errors int64
	latencies := make(chan time.Duration, 100_000)

	for i := 0; i < concurrent; i++ {
		go func() {
			for {
				select {
				case <-stop:
					return
				default:
				}
				start := time.Now()
				req := mustNewRequest(t, "GET", f.proxy.URL+"/api/x", nil)
				req.RemoteAddr = "100.64.0.5:54321"
				resp, err := http.DefaultClient.Do(req)
				if err != nil || resp.StatusCode != 200 {
					atomic.AddInt64(&errors, 1)
					if resp != nil {
						resp.Body.Close()
					}
					continue
				}
				resp.Body.Close()
				atomic.AddInt64(&requests, 1)
				select {
				case latencies <- time.Since(start):
				default:
				}
			}
		}()
	}

	time.Sleep(duration)
	close(stop)
	close(latencies)

	collected := make([]time.Duration, 0, len(latencies))
	for d := range latencies {
		collected = append(collected, d)
	}
	if len(collected) == 0 {
		t.Fatal("no successful requests recorded")
	}
	sort.Slice(collected, func(i, j int) bool { return collected[i] < collected[j] })

	rps := float64(requests) / duration.Seconds()
	p50 := collected[len(collected)/2]
	p99 := collected[len(collected)*99/100]

	t.Logf("perf: rps=%.0f requests=%d errors=%d p50=%v p99=%v",
		rps, requests, errors, p50, p99)

	if rps < 1000 {
		t.Errorf("throughput: want ≥ 1000 rps, got %.0f", rps)
	}
	if p99 > 50*time.Millisecond {
		t.Errorf("p99 latency: want ≤ 50 ms, got %v", p99)
	}
}

// ──────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────

func mustNewRequest(t *testing.T, method, url string, body io.Reader) *http.Request {
	t.Helper()
	req, err := http.NewRequest(method, url, body)
	if err != nil {
		t.Fatal(err)
	}
	return req
}

// verifyJWT decodes the compact JWS and verifies the signature
// against the supplied public key, then asserts a few claims.
func verifyJWT(t *testing.T, jws string, pub *rsa.PublicKey) {
	t.Helper()
	parts := strings.Split(jws, ".")
	if len(parts) != 3 {
		t.Fatalf("not a compact JWS: %q", jws)
	}

	signingInput := parts[0] + "." + parts[1]
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatalf("decode sig: %v", err)
	}
	hashed := sha256.Sum256([]byte(signingInput))
	if err := rsa.VerifyPKCS1v15(pub, crypto.SHA256, hashed[:], sig); err != nil {
		t.Fatalf("JWT signature did not verify: %v", err)
	}

	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var claims map[string]any
	if err := json.Unmarshal(payload, &claims); err != nil {
		t.Fatal(err)
	}
	if claims["user_id"] != "u-1" {
		t.Errorf("claim user_id: want u-1, got %v", claims["user_id"])
	}
	if claims["email"] != "alice@example.com" {
		t.Errorf("claim email: got %v", claims["email"])
	}
}
