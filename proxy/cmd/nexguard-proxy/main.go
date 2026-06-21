// Command nexguard-proxy is the L7 ZTNA transparent proxy (ADR-007).
//
// Phase 1 of L7-D (this commit) wires up:
//   - Bundle client polling the NexGuard server at /internal/bundle.json
//   - Identity client for per-VPN-IP lookups with a 30 s cache
//   - Structured slog/JSON logger
//
// What's NOT here yet (later L7-D commits):
//   - TLS listener on :8443
//   - IP_TRANSPARENT socket + SO_ORIGINAL_DST steer (Linux-only)
//   - L7 rule eval (group intersection + method/path/MFA-age)
//   - JWT signing + identity header injection
//   - Reverse proxy to backend
//   - /metrics + /healthz + /readyz
//
// Run with NEXGUARD_SERVER_URL set:
//
//	NEXGUARD_SERVER_URL=https://nexguard.example.com \
//	NEXGUARD_PROXY_LOG_LEVEL=debug \
//	  ./nexguard-proxy
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/0xphuong/NexGuard/proxy/internal/bundle"
	"github.com/0xphuong/NexGuard/proxy/internal/identity"
	"github.com/0xphuong/NexGuard/proxy/internal/logging"
)

const (
	envServerURL     = "NEXGUARD_SERVER_URL"
	bundlePollPeriod = 30 * time.Second
)

func main() {
	log := logging.New()

	serverURL, err := getRequiredURL(envServerURL)
	if err != nil {
		log.Error("startup failed", "error", err)
		os.Exit(1)
	}

	log.Info("nexguard-proxy starting",
		slog.String("server_url", serverURL.String()),
		slog.String("phase", "L7-D Phase 1 (bones)"),
	)

	ctx, cancel := signal.NotifyContext(context.Background(),
		syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	bc := bundle.New(serverURL.String())
	ic := identity.New(serverURL.String())

	if err := bootstrapBundle(ctx, log, bc); err != nil {
		log.Error("bundle bootstrap failed", "error", err)
		os.Exit(1)
	}

	// Stub: poll the bundle endpoint to demonstrate the client works.
	// A later commit replaces this with PubSub-driven refresh (SSE or
	// websocket from the NexGuard server).
	go pollBundle(ctx, log, bc)

	log.Info("bones ready; awaiting later commits for TLS + TPROXY + reverse proxy")
	// Silence the unused-import nag — ic will be wired into the
	// request hot path once the TLS listener lands.
	_ = ic

	<-ctx.Done()
	log.Info("shutting down on signal")
}

func getRequiredURL(env string) (*url.URL, error) {
	raw := os.Getenv(env)
	if raw == "" {
		return nil, errors.New(env + " must be set")
	}
	u, err := url.Parse(raw)
	if err != nil {
		return nil, err
	}
	if u.Scheme == "" || u.Host == "" {
		return nil, errors.New(env + " must be an absolute URL with scheme")
	}
	return u, nil
}

func bootstrapBundle(ctx context.Context, log *slog.Logger, bc *bundle.Client) error {
	v, _, err := bc.Fetch(ctx)
	if err != nil {
		return err
	}
	log.Info("bundle bootstrap complete", slog.Int("version", v))
	return nil
}

func pollBundle(ctx context.Context, log *slog.Logger, bc *bundle.Client) {
	t := time.NewTicker(bundlePollPeriod)
	defer t.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			v, changed, err := bc.Fetch(ctx)
			if err != nil {
				log.Warn("bundle poll failed", "error", err)
				continue
			}
			if changed {
				log.Info("bundle updated", slog.Int("version", v))
			}
		}
	}
}
