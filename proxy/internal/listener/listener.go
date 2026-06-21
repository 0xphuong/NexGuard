// Package listener builds the L7 proxy's user-facing TCP listener
// (ADR-007 + L7-C TPROXY plumbing).
//
// Production target: Linux with the IP_TRANSPARENT socket option +
// the fwmark/iproute2 setup from fz_wall (L7-C). Under that setup
// the kernel delivers packets destined for any VIP in 10.99.0.0/16
// to this single listener at 127.0.0.1:8443 (or whatever
// :ListenAddr is bound to), and `conn.LocalAddr()` on each accept
// returns the ORIGINAL destination — i.e. the VIP — so the
// request handler knows which app the client tried to reach.
//
// Non-Linux platforms get a stub that errors at listen time so dev
// builds compile but operators don't accidentally deploy without
// the kernel features.
package listener

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"

	"github.com/0xphuong/NexGuard/proxy/internal/cert"
)

// Config gathers the static settings the listener needs at boot.
type Config struct {
	// ListenAddr is the TCP address to bind (e.g. "127.0.0.1:8443").
	// Per the TPROXY setup in fz_wall, packets to VIPs in
	// 10.99.0.0/16 are redirected here by the kernel; the listener
	// itself does not need to bind to a VIP.
	ListenAddr string

	// Certificates resolves the SNI hostname to a *tls.Certificate.
	// Wire a `*cert.Holder` here so bundle pivots automatically
	// refresh the certificates a future handshake sees.
	Certificates *cert.Holder
}

// Listen opens an IP_TRANSPARENT TCP listener at cfg.ListenAddr and
// wraps it in a TLS listener using the supplied cert holder. The
// returned net.Listener yields *tls.Conn from Accept(), and each
// conn's LocalAddr() carries the original destination VIP — the
// caller uses that to look up which app the connection targeted.
//
// Sets MinVersion = TLS 1.3 (ADR-007 consequence note); older
// versions are explicitly rejected.
func Listen(ctx context.Context, cfg Config) (net.Listener, error) {
	if cfg.ListenAddr == "" {
		return nil, errors.New("listener: ListenAddr is required")
	}
	if cfg.Certificates == nil {
		return nil, errors.New("listener: Certificates holder is required")
	}

	lc := net.ListenConfig{Control: setTransparent}

	tcp, err := lc.Listen(ctx, "tcp4", cfg.ListenAddr)
	if err != nil {
		return nil, fmt.Errorf("listener: tcp listen %q: %w", cfg.ListenAddr, err)
	}

	tlsCfg := &tls.Config{
		MinVersion:     tls.VersionTLS13,
		GetCertificate: cfg.Certificates.GetCertificate,
	}

	return tls.NewListener(tcp, tlsCfg), nil
}

// OriginalDST returns the VIP the client was originally trying to
// reach for a given accepted connection. Convenience over the TPROXY
// model's `conn.LocalAddr()` behavior, with a clear error for the
// non-Linux fallback case.
func OriginalDST(c net.Conn) (*net.TCPAddr, error) {
	addr := c.LocalAddr()
	tcpAddr, ok := addr.(*net.TCPAddr)
	if !ok {
		return nil, fmt.Errorf("listener: LocalAddr is %T, want *net.TCPAddr", addr)
	}
	return tcpAddr, nil
}
