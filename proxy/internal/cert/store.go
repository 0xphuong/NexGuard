// Package cert maps SNI hostnames to TLS certificates loaded out of
// the policy bundle (ADR-009). Used by the proxy's TLS listener
// `GetCertificate` callback on the hot path of every TLS handshake.
package cert

import (
	"crypto/tls"
	"errors"
	"fmt"
	"sync/atomic"

	"github.com/0xphuong/NexGuard/proxy/internal/bundle"
)

// ErrUnknownHost is returned when a client sends an SNI hostname
// that no declared app claims. The TLS library surfaces this as a
// handshake failure to the client; the proxy logs the SNI value for
// "unknown app" forensics (handled by the deny-page layer in a
// later commit).
var ErrUnknownHost = errors.New("cert: no app declares this hostname")

// Store is an immutable snapshot of `hostname → *tls.Certificate`
// derived from one Bundle. Reads (GetCertificate) take a single
// atomic load with no lock; bundle pivots build a new Store and
// atomic-swap it into Holder.
type Store struct {
	byHostname map[string]*tls.Certificate
}

// FromBundle builds a Store from the apps in b. Skips apps that
// have no cert material (e.g. proxy-only declared but cert pending).
// Returns an error only on parse failure of a present cert — admins
// shouldn't be able to save an unparseable PEM via the UI, but a
// stale bundle could carry one.
func FromBundle(b *bundle.Bundle) (*Store, error) {
	s := &Store{byHostname: make(map[string]*tls.Certificate, len(b.Apps))}

	for i := range b.Apps {
		app := &b.Apps[i]
		// passthrough apps don't terminate TLS — skip cert load.
		if app.TLSMode == "passthrough" {
			continue
		}
		if app.CertPEM == "" || app.KeyPEM == "" {
			// No cert yet (e.g. step_ca about to issue) — let the
			// TLS handshake fail with ErrUnknownHost rather than
			// failing the whole store load.
			continue
		}

		cert, err := tls.X509KeyPair([]byte(app.CertPEM), []byte(app.KeyPEM))
		if err != nil {
			return nil, fmt.Errorf("cert: parse app %q (%q): %w", app.ID, app.Hostname, err)
		}
		s.byHostname[app.Hostname] = &cert
	}

	return s, nil
}

// Get returns the certificate matching serverName, or ErrUnknownHost.
// The TLS lookup is exact-match — no wildcard expansion here; if an
// admin uploaded a wildcard cert (e.g. "*.example.com"), the rendered
// app hostname IS the wildcard, and clients must SNI exactly that
// string. Browsers normally don't send wildcards as SNI, so this is
// rarely useful; we keep it consistent with what was uploaded.
func (s *Store) Get(serverName string) (*tls.Certificate, error) {
	if c, ok := s.byHostname[serverName]; ok {
		return c, nil
	}
	return nil, ErrUnknownHost
}

// Size reports the number of hosts the store can serve. Useful for
// log lines on bundle pivot.
func (s *Store) Size() int { return len(s.byHostname) }

// Holder is a goroutine-safe atomic slot for *Store, mirroring
// jwt.SignerHolder. Request handlers read with Get(); the bundle
// poller writes with Set on every pivot.
type Holder struct {
	v atomic.Pointer[Store]
}

func (h *Holder) Set(s *Store) { h.v.Store(s) }
func (h *Holder) Get() *Store  { return h.v.Load() }

// GetCertificate is the callback shape `tls.Config.GetCertificate`
// wants. Bound to a Holder so the live Store is always current.
func (h *Holder) GetCertificate(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
	s := h.Get()
	if s == nil {
		return nil, errors.New("cert: store not yet loaded (proxy still booting?)")
	}
	return s.Get(hello.ServerName)
}
