// Package handler is the L7 proxy request hot path (ADR-007,
// ADR-010, ADR-014). One `http.Handler` runs the full pipeline per
// inbound TLS-terminated HTTP request:
//
//	1. Resolve app from original-destination VIP (carried via
//	   ConnContext localAddrKey on the underlying conn).
//	2. Lookup identity from client VPN IP (resolved from
//	   r.RemoteAddr; 30 s cache lives in the identity client).
//	3. Evaluate policy (break-glass → app group gate → rule eval).
//	4. Sign + inject the identity headers (plain + JWT per ADR-010).
//	5. Strip user-spoofed `X-NexGuard-*` headers.
//	6. Reverse proxy to the app's backend.
//
// Errors at any stage map to a sanitized HTML deny page with an
// `X-NexGuard-Reason` header so operators can grep logs / browsers
// show a clear "why was I denied" message without revealing
// internal hostnames.
package handler

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"time"

	"github.com/0xphuong/NexGuard/proxy/internal/bundle"
	"github.com/0xphuong/NexGuard/proxy/internal/cert"
	"github.com/0xphuong/NexGuard/proxy/internal/identity"
	"github.com/0xphuong/NexGuard/proxy/internal/jwt"
	"github.com/0xphuong/NexGuard/proxy/internal/observability"
	"github.com/0xphuong/NexGuard/proxy/internal/policy"
)

// LocalAddrKey is the context key the listener installs onto each
// request's ctx via http.Server.ConnContext, carrying the
// IP_TRANSPARENT socket's `conn.LocalAddr()` (the original VIP).
//
// Defined as a typed key per stdlib best practice.
type localAddrKeyType struct{}

var LocalAddrKey = localAddrKeyType{}

// Deps holds the live dependencies the handler reads per request.
// All are pointer-or-holder types so a bundle pivot atomically
// reflects in the next request without re-creating the handler.
type Deps struct {
	Bundle       *bundle.Client
	Identity     *identity.Client
	Signers      *jwt.SignerHolder
	Certs        *cert.Holder // unused on the HTTP hot path; passed in case we want a debug endpoint
	DenyPage     func(w http.ResponseWriter, code int, reason, hostname, requestID string)
	HeaderPrefix string // typically "X-NexGuard-"
	Logger       *slog.Logger // structured per-request access log; defaults to a discard logger
	Metrics      *observability.Metrics // safe to leave nil — RecordRequest is a no-op on nil receiver
}

// New builds the handler wiring its dependencies. DenyPage defaults
// to the bundled HTML template if nil.
func New(d Deps) http.Handler {
	if d.DenyPage == nil {
		d.DenyPage = RenderDenyHTML
	}
	if d.HeaderPrefix == "" {
		d.HeaderPrefix = "X-NexGuard-"
	}
	if d.Logger == nil {
		d.Logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	return &proxy{deps: d}
}

type proxy struct {
	deps Deps
}

// reasons surfaced on X-NexGuard-Reason header + deny page.
const (
	reasonUnknownApp     = "unknown-app"
	reasonUnknownVPNIP   = "unknown-vpn-ip"
	reasonDenied         = "denied"
	reasonNoBundle       = "no-bundle"
	reasonBackendError   = "backend-error"
	reasonBackendInvalid = "backend-invalid"
)

// recordingWriter is a minimal http.ResponseWriter wrapper that
// captures status code + bytes written for the access log. We use
// the local declaration rather than a middleware so callers don't
// need a separate wiring step — and so the deny path's manual
// w.WriteHeader is observed too.
type recordingWriter struct {
	http.ResponseWriter
	status int
	bytes  int64
}

func (rw *recordingWriter) WriteHeader(code int) {
	// stdlib's http.ResponseWriter already complains on a second
	// WriteHeader, but our access log only captures the FIRST status
	// so the metric counter labels match what the client saw. The
	// guard also matters on the deny path: if a backend wrote a
	// status before ErrorHandler tried to render the deny page, the
	// log entry should keep the original code.
	if rw.status != 0 {
		return
	}
	rw.status = code
	rw.ResponseWriter.WriteHeader(code)
}

func (rw *recordingWriter) Write(b []byte) (int, error) {
	if rw.status == 0 {
		rw.status = http.StatusOK
	}
	n, err := rw.ResponseWriter.Write(b)
	rw.bytes += int64(n)
	return n, err
}

// v3.0.2: expose the optional `http.ResponseWriter` capabilities
// (Flusher, Hijacker, Pusher, io.ReaderFrom) that the underlying
// `net/http` writer supports. Without these delegations Go's
// stdlib `httputil.ReverseProxy` sees the wrapper's concrete type,
// fails the `w.(http.Flusher)` assertion, and silently disables
// per-write flushing on streaming responses. Effect: any response
// with `Content-Type: text/event-stream` (SSE) or a chunked
// transfer with no Content-Length (long-poll, streaming APIs)
// buffers indefinitely on the server side -- the client sees the
// TCP connection as "pending" until the backend closes it. Symptom
// caught on ArgoCD's `/api/v1/stream/applications/*` endpoint,
// where the SPA relies on EventSource to reflect sync state in
// real time. Regular XHR responses complete + flush at handler
// return so they appear to work; only streaming responses expose
// the missing capability.
//
// Delegation pattern is the canonical Go fix for
// ResponseWriter wrappers -- documented in Go's own
// `httptest.NewRecorder` and every mature middleware library.

// Flush surfaces backend writes to the client immediately. Required
// for SSE (`text/event-stream`), long-poll responses, gRPC-over-h2c,
// and anything else where the client expects incremental data.
func (rw *recordingWriter) Flush() {
	if f, ok := rw.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// Hijack lets `httputil.ReverseProxy` take over the raw TCP
// connection for WebSocket / CONNECT / HTTP upgrade flows. Without
// this, an upgraded response falls back to buffered HTTP handling
// and the socket never bidi-streams. `bytes` / `status` fields
// stop tracking after hijack -- that's expected; hijacked
// connections are outside the HTTP request model.
func (rw *recordingWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if h, ok := rw.ResponseWriter.(http.Hijacker); ok {
		return h.Hijack()
	}
	return nil, nil, http.ErrNotSupported
}

// ReadFrom lets the stdlib copy loop pick the fast path (sendfile
// / splice on Linux) instead of allocating a heap buffer per copy.
// Only forwards when the underlying writer implements io.ReaderFrom,
// which stdlib's response writer does. Byte counting is preserved
// so the access log's `bytes_out` stays accurate.
func (rw *recordingWriter) ReadFrom(src io.Reader) (int64, error) {
	if rw.status == 0 {
		rw.status = http.StatusOK
	}
	rf, ok := rw.ResponseWriter.(io.ReaderFrom)
	if !ok {
		n, err := io.Copy(rw.ResponseWriter, src)
		rw.bytes += n
		return n, err
	}
	n, err := rf.ReadFrom(src)
	rw.bytes += n
	return n, err
}

// observation accumulates structured-log fields as the request
// travels the pipeline. Updated by each stage; consumed by the
// deferred log + metric emit at the end of ServeHTTP.
type observation struct {
	requestID string // short hex ID, also rendered on deny pages
	appID     string
	userID    string
	decision  string // allow | deny | error
	reason    string
	vip       string
}

// queryKeys returns a comma-separated list of query parameter NAMES
// from r.URL — no values. Used in the access log so operators can
// see which params a request carried (e.g. `?next=…&token=…`)
// without the secrets that live in the values.
func queryKeys(u *url.URL) string {
	if u == nil || u.RawQuery == "" {
		return ""
	}
	q := u.Query()
	if len(q) == 0 {
		return ""
	}
	keys := make([]string, 0, len(q))
	for k := range q {
		keys = append(keys, k)
	}
	return strings.Join(keys, ",")
}

// newRequestID returns an 8-byte random hex (16 chars). Short enough
// for a user to read off a deny page and paste into a support
// ticket; entropy enough that collisions across one access-log
// retention window are negligible.
func newRequestID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	rec := &recordingWriter{ResponseWriter: w}
	obs := &observation{
		requestID: newRequestID(),
		decision:  "error",
		reason:    "uninitialized",
	}

	// Surface the request ID on every response (deny + allow). The
	// deny page also shows it in human-readable form so users can
	// copy-paste into a support request and the admin can grep the
	// access log for the matching entry.
	w.Header().Set(p.deps.HeaderPrefix+"Request-Id", obs.requestID)

	defer func() {
		dur := time.Since(start)
		p.deps.Logger.Info("request",
			slog.String("request_id", obs.requestID),
			slog.String("decision", obs.decision),
			slog.String("reason", obs.reason),
			slog.String("app_id", obs.appID),
			slog.String("user_id", obs.userID),
			slog.String("vip", obs.vip),
			slog.Int("status", rec.status),
			slog.Int64("bytes_out", rec.bytes),
			slog.Duration("latency", dur),
			slog.String("method", r.Method),
			// `r.URL.Path` is the path-only component — Go's parser
			// separates path from query, so tokens in query strings
			// (e.g. /reset?token=abc) never reach the access log.
			// Query KEY NAMES (without values) are logged for debug
			// visibility — useful for spotting common params without
			// leaking secrets. Note: secrets in the URL PATH itself
			// (e.g. /reset/<token>) WILL be logged; backends should
			// avoid putting secrets in path components.
			slog.String("path", r.URL.Path),
			slog.String("query_keys", queryKeys(r.URL)),
			slog.String("ua", r.UserAgent()),
			slog.String("client", r.RemoteAddr),
		)
		p.deps.Metrics.RecordRequest(obs.decision, rec.status, dur.Seconds())
	}()

	p.handle(rec, r, obs)
}

func (p *proxy) handle(w http.ResponseWriter, r *http.Request, obs *observation) {
	b := p.deps.Bundle.Current()
	if b == nil {
		obs.decision, obs.reason = "error", reasonNoBundle
		p.deny(w, r, obs, http.StatusServiceUnavailable, reasonNoBundle, "")
		return
	}

	// 1. App resolution from LocalAddr (original VIP).
	vip, ok := localAddrIP(r.Context())
	if !ok {
		obs.decision, obs.reason = "error", reasonUnknownApp
		p.deny(w, r, obs, http.StatusInternalServerError, reasonUnknownApp, "")
		return
	}
	obs.vip = vip
	app := b.FindAppByVIP(vip)
	if app == nil {
		obs.decision, obs.reason = "deny", reasonUnknownApp
		p.deny(w, r, obs, http.StatusNotFound, reasonUnknownApp, "")
		return
	}
	obs.appID = app.ID

	// 2. Identity from client VPN IP. Refuse to fall back to the
	//    raw string on a parse failure — a malformed RemoteAddr
	//    would otherwise hash to a different cache key than the
	//    server keys identity by, breaking invalidation.
	clientIP, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		obs.decision, obs.reason = "error", reasonUnknownVPNIP
		p.deny(w, r, obs, http.StatusBadRequest, reasonUnknownVPNIP, app.Hostname)
		return
	}
	id, err := p.deps.Identity.Lookup(r.Context(), clientIP)
	if err != nil {
		if errors.Is(err, identity.ErrUnknownVPNIP) {
			obs.decision, obs.reason = "deny", reasonUnknownVPNIP
			p.deny(w, r, obs, http.StatusUnauthorized, reasonUnknownVPNIP, app.Hostname)
			return
		}
		obs.decision, obs.reason = "error", reasonBackendError
		p.deny(w, r, obs, http.StatusBadGateway, reasonBackendError, app.Hostname)
		return
	}
	obs.userID = id.UserID

	// 3. Policy evaluation.
	dec := policy.Decide(b, app, id, r)
	if !dec.Allow {
		obs.decision, obs.reason = "deny", dec.Reason
		p.deny(w, r, obs, http.StatusForbidden, reasonDenied, app.Hostname)
		return
	}

	// 4. Header massage in dependency order:
	//
	//    a. Strip any client-supplied X-NexGuard-* (defense vs spoof).
	//    b. Apply per-app strip_headers (admin policy, e.g. drop
	//       Cookie before forwarding).
	//    c. Apply per-app inject_headers, BUT refuse to overwrite
	//       anything in our reserved X-NexGuard-* namespace —
	//       otherwise a misconfigured app config could blank or
	//       impersonate identity headers.
	//    d. Last writer wins for identity headers (plain + JWT) so
	//       neither client nor admin policy can substitute.
	p.stripSpoofedHeaders(r)
	for _, name := range app.StripHeaders {
		r.Header.Del(name)
	}
	for _, h := range app.InjectHeaders {
		if isReservedHeader(h.Name, p.deps.HeaderPrefix) {
			continue // admin can't impersonate identity
		}
		r.Header.Set(h.Name, h.Value)
	}
	p.injectIdentityHeaders(r, id)
	if err := p.injectJWT(r, id, app); err != nil {
		obs.decision, obs.reason = "error", reasonBackendError
		p.deny(w, r, obs, http.StatusInternalServerError, reasonBackendError, app.Hostname)
		return
	}

	// 5. Reverse proxy.
	rp, err := p.buildReverseProxy(app, obs)
	if err != nil {
		obs.decision, obs.reason = "error", reasonBackendInvalid
		p.deny(w, r, obs, http.StatusInternalServerError, reasonBackendInvalid, app.Hostname)
		return
	}

	obs.decision, obs.reason = "allow", dec.Reason
	rp.ServeHTTP(w, r)
}

// localAddrIP pulls the proxy's TPROXY-recovered VIP out of the
// request context. Returns "" if the value wasn't installed (e.g.
// running unit tests without a wrapping http.Server).
func localAddrIP(ctx context.Context) (string, bool) {
	v := ctx.Value(LocalAddrKey)
	if v == nil {
		return "", false
	}
	addr, ok := v.(net.Addr)
	if !ok {
		return "", false
	}
	tcp, ok := addr.(*net.TCPAddr)
	if !ok {
		return "", false
	}
	return tcp.IP.String(), true
}

// xffSpoofHeaders is the well-known set of forwarded-IP headers
// downstream backends use to learn the client's IP. We strip them
// from the incoming request so Go's stdlib httputil.ReverseProxy
// (which APPENDS to X-Forwarded-For after the Director runs) sets
// the header to ONLY the proxy-observed client IP. Without this
// strip, a client sending `X-Forwarded-For: 1.2.3.4` would end up
// with `X-Forwarded-For: 1.2.3.4, 10.0.55.10` reaching the backend
// — and naive backends that trust the FIRST entry get spoofed.
var xffSpoofHeaders = []string{
	"X-Forwarded-For",
	"X-Forwarded-Proto",
	"X-Forwarded-Host",
	"X-Forwarded-Port",
	"X-Real-Ip",
	"Forwarded", // RFC 7239
	"Via",
}

func (p *proxy) stripSpoofedHeaders(r *http.Request) {
	// net/http canonicalizes header keys (`X-NexGuard-` becomes
	// `X-Nexguard-` because canonical title-cases only the first
	// letter after each dash). The shared stripReservedHeaders
	// helper handles the case-insensitive walk; this is the entry
	// point on the ingress (client → proxy) leg.
	stripReservedHeaders(r.Header, p.deps.HeaderPrefix)

	// XFF / Forwarded family — see comment on xffSpoofHeaders.
	for _, name := range xffSpoofHeaders {
		r.Header.Del(name)
	}
}

func (p *proxy) injectIdentityHeaders(r *http.Request, id *identity.Identity) {
	h := p.deps.HeaderPrefix
	r.Header.Set(h+"User-Id", id.UserID)
	r.Header.Set(h+"User-Email", id.Email)
	r.Header.Set(h+"User-Role", id.Role)
	r.Header.Set(h+"Groups", strings.Join(id.Groups, ","))
	if id.MFAAgeSeconds != nil {
		r.Header.Set(h+"MFA-Age-Seconds", fmt.Sprintf("%d", *id.MFAAgeSeconds))
	}
}

func (p *proxy) injectJWT(r *http.Request, id *identity.Identity, app *bundle.App) error {
	s := p.deps.Signers.Get()
	if s == nil {
		return errors.New("handler: no signer loaded")
	}
	// `aud` = app.ID pins the token to this specific app. A backend
	// that strictly verifies aud rejects a token minted for a
	// different app — closing the cross-app replay window the
	// previous Claims schema left open.
	jws, err := s.Sign(jwt.Claims{
		UserID:        id.UserID,
		Email:         id.Email,
		Groups:        id.Groups,
		MFAAgeSeconds: id.MFAAgeSeconds,
	}, app.ID, 0)
	if err != nil {
		return err
	}
	r.Header.Set(p.deps.HeaderPrefix+"Identity-Jwt", jws)
	return nil
}

// allowedBackendSchemes constrains app.Backend to plain HTTP(S) —
// no file://, gopher://, etc. SSRF defense vs an attacker who
// compromises bundle compilation.
var allowedBackendSchemes = map[string]bool{"http": true, "https": true}

func (p *proxy) buildReverseProxy(app *bundle.App, obs *observation) (*httputil.ReverseProxy, error) {
	target, err := url.Parse(app.Backend)
	if err != nil {
		return nil, fmt.Errorf("handler: parse backend %q: %w", app.Backend, err)
	}
	if target.Scheme == "" || target.Host == "" {
		return nil, fmt.Errorf("handler: backend %q missing scheme or host", app.Backend)
	}
	if !allowedBackendSchemes[target.Scheme] {
		return nil, fmt.Errorf("handler: backend scheme %q not allowed", target.Scheme)
	}

	rp := httputil.NewSingleHostReverseProxy(target)

	// Set Host to the upstream target so vhost-based backends route
	// to the right virtual host. Without this, a malicious client
	// could spoof Host: vendor.example to pivot inside the
	// upstream's vhost map.
	origDirector := rp.Director
	rp.Director = func(req *http.Request) {
		origDirector(req)
		req.Host = target.Host
	}

	// Outbound TLS pinned to >= TLS 1.2; ADR-007 forbids weaker.
	// HTTP/2 attempts enabled to match what stdlib's
	// DefaultTransport does but with the version pin.
	rp.Transport = &http.Transport{
		TLSClientConfig:   &tls.Config{MinVersion: tls.VersionTLS12},
		ForceAttemptHTTP2: true,
		Proxy:             http.ProxyFromEnvironment,
	}

	// Strip any X-NexGuard-* the backend might inject in its
	// response — clients must not see anything that looks like
	// proxy-set identity material coming back from the backend.
	rp.ModifyResponse = func(resp *http.Response) error {
		stripReservedHeaders(resp.Header, p.deps.HeaderPrefix)
		return nil
	}

	rp.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		p.deny(w, r, obs, http.StatusBadGateway, reasonBackendError, app.Hostname)
	}

	return rp, nil
}

// isReservedHeader reports whether name (case-insensitive) starts
// with the proxy's reserved prefix — typically "X-NexGuard-". Used
// to reject admin-controlled overrides of identity headers.
func isReservedHeader(name, prefix string) bool {
	return strings.HasPrefix(strings.ToLower(name), strings.ToLower(prefix))
}

// stripReservedHeaders deletes every header (case-insensitive) under
// the proxy's prefix. Shared between request ingress and response
// egress paths.
func stripReservedHeaders(h http.Header, prefix string) {
	low := strings.ToLower(prefix)
	for name := range h {
		if strings.HasPrefix(strings.ToLower(name), low) {
			h.Del(name)
		}
	}
}

// deny renders the HTML deny page with the X-NexGuard-Reason header set.
// The deny page surfaces a request ID the user can quote in a support
// ticket; admins grep the access log for the matching entry. The
// observation struct is the canonical source of that ID — same value
// gets logged so user-facing ID == log entry ID.
func (p *proxy) deny(w http.ResponseWriter, r *http.Request, obs *observation, code int, reason, hostname string) {
	w.Header().Set(p.deps.HeaderPrefix+"Reason", reason)
	p.deps.DenyPage(w, code, reason, hostname, obs.requestID)
}
