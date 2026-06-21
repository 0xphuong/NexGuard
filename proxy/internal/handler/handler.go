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
	"context"
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
	DenyPage     func(w http.ResponseWriter, code int, reason, hostname string)
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

// observation accumulates structured-log fields as the request
// travels the pipeline. Updated by each stage; consumed by the
// deferred log + metric emit at the end of ServeHTTP.
type observation struct {
	appID    string
	userID   string
	decision string // allow | deny | error
	reason   string
	vip      string
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	rec := &recordingWriter{ResponseWriter: w}
	obs := &observation{decision: "error", reason: "uninitialized"}

	defer func() {
		dur := time.Since(start)
		p.deps.Logger.Info("request",
			slog.String("decision", obs.decision),
			slog.String("reason", obs.reason),
			slog.String("app_id", obs.appID),
			slog.String("user_id", obs.userID),
			slog.String("vip", obs.vip),
			slog.Int("status", rec.status),
			slog.Int64("bytes_out", rec.bytes),
			slog.Duration("latency", dur),
			slog.String("method", r.Method),
			slog.String("path", r.URL.Path),
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
		p.deny(w, r, http.StatusServiceUnavailable, reasonNoBundle, "")
		return
	}

	// 1. App resolution from LocalAddr (original VIP).
	vip, ok := localAddrIP(r.Context())
	if !ok {
		obs.decision, obs.reason = "error", reasonUnknownApp
		p.deny(w, r, http.StatusInternalServerError, reasonUnknownApp, "")
		return
	}
	obs.vip = vip
	app := b.FindAppByVIP(vip)
	if app == nil {
		obs.decision, obs.reason = "deny", reasonUnknownApp
		p.deny(w, r, http.StatusNotFound, reasonUnknownApp, "")
		return
	}
	obs.appID = app.ID

	// 2. Identity from client VPN IP.
	clientIP, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		clientIP = r.RemoteAddr
	}
	id, err := p.deps.Identity.Lookup(r.Context(), clientIP)
	if err != nil {
		if errors.Is(err, identity.ErrUnknownVPNIP) {
			obs.decision, obs.reason = "deny", reasonUnknownVPNIP
			p.deny(w, r, http.StatusUnauthorized, reasonUnknownVPNIP, app.Hostname)
			return
		}
		obs.decision, obs.reason = "error", reasonBackendError
		p.deny(w, r, http.StatusBadGateway, reasonBackendError, app.Hostname)
		return
	}
	obs.userID = id.UserID

	// 3. Policy evaluation.
	dec := policy.Decide(b, app, id, r)
	if !dec.Allow {
		obs.decision, obs.reason = "deny", dec.Reason
		p.deny(w, r, http.StatusForbidden, reasonDenied, app.Hostname)
		return
	}

	// 4. Header inject (plain + JWT). Plain headers are convenience
	//    for backends that don't verify JWTs; the JWT is the
	//    auditable signed source of truth.
	p.stripSpoofedHeaders(r)
	p.injectIdentityHeaders(r, id)
	if err := p.injectJWT(r, id); err != nil {
		obs.decision, obs.reason = "error", reasonBackendError
		p.deny(w, r, http.StatusInternalServerError, reasonBackendError, app.Hostname)
		return
	}
	for _, h := range app.InjectHeaders {
		r.Header.Set(h.Name, h.Value)
	}
	for _, name := range app.StripHeaders {
		r.Header.Del(name)
	}

	// 5. Reverse proxy.
	rp, err := p.buildReverseProxy(app)
	if err != nil {
		obs.decision, obs.reason = "error", reasonBackendInvalid
		p.deny(w, r, http.StatusInternalServerError, reasonBackendInvalid, app.Hostname)
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

func (p *proxy) stripSpoofedHeaders(r *http.Request) {
	// net/http canonicalizes header keys (`X-NexGuard-` becomes
	// `X-Nexguard-` because canonical title-cases only the first
	// letter after each dash). Strip case-insensitively to catch
	// anything the client tried regardless of casing.
	prefix := strings.ToLower(p.deps.HeaderPrefix)
	for name := range r.Header {
		if strings.HasPrefix(strings.ToLower(name), prefix) {
			r.Header.Del(name)
		}
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

func (p *proxy) injectJWT(r *http.Request, id *identity.Identity) error {
	s := p.deps.Signers.Get()
	if s == nil {
		return errors.New("handler: no signer loaded")
	}
	jws, err := s.Sign(jwt.Claims{
		UserID:        id.UserID,
		Email:         id.Email,
		Groups:        id.Groups,
		MFAAgeSeconds: id.MFAAgeSeconds,
	}, 0)
	if err != nil {
		return err
	}
	r.Header.Set(p.deps.HeaderPrefix+"Identity-Jwt", jws)
	return nil
}

func (p *proxy) buildReverseProxy(app *bundle.App) (*httputil.ReverseProxy, error) {
	target, err := url.Parse(app.Backend)
	if err != nil {
		return nil, fmt.Errorf("handler: parse backend %q: %w", app.Backend, err)
	}
	if target.Scheme == "" || target.Host == "" {
		return nil, fmt.Errorf("handler: backend %q missing scheme or host", app.Backend)
	}

	rp := httputil.NewSingleHostReverseProxy(target)

	// Preserve the request's outgoing Host header — let the backend
	// see the client-supplied hostname rather than the upstream
	// target. Matches what most reverse-proxies expect; some
	// backends (vhost-based servers) need this exact behavior.
	origDirector := rp.Director
	rp.Director = func(req *http.Request) {
		origDirector(req)
		// Don't overwrite the Host we just preserved.
	}

	rp.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		p.deny(w, r, http.StatusBadGateway, reasonBackendError, app.Hostname)
	}

	return rp, nil
}

// deny renders the HTML deny page with the X-NexGuard-Reason header set.
func (p *proxy) deny(w http.ResponseWriter, r *http.Request, code int, reason, hostname string) {
	w.Header().Set(p.deps.HeaderPrefix+"Reason", reason)
	p.deps.DenyPage(w, code, reason, hostname)
}
