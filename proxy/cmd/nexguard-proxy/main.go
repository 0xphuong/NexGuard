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
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/0xphuong/NexGuard/proxy/internal/bundle"
	"github.com/0xphuong/NexGuard/proxy/internal/cert"
	"github.com/0xphuong/NexGuard/proxy/internal/handler"
	"github.com/0xphuong/NexGuard/proxy/internal/identity"
	"github.com/0xphuong/NexGuard/proxy/internal/jwt"
	"github.com/0xphuong/NexGuard/proxy/internal/listener"
	"github.com/0xphuong/NexGuard/proxy/internal/logging"
	"github.com/0xphuong/NexGuard/proxy/internal/observability"
)

const (
	envServerURL       = "NEXGUARD_SERVER_URL"
	envListenAddr      = "NEXGUARD_PROXY_LISTEN"
	envObsAddr         = "NEXGUARD_PROXY_OBS_LISTEN"
	defaultListenAddr  = "127.0.0.1:8443"
	defaultObsAddr     = "127.0.0.1:9090"
	bundlePollPeriod   = 30 * time.Second
)

func main() {
	// Docker HEALTHCHECK helper. Hits /readyz on the obs port and
	// exits 0 (ready) / 1 (not ready or unreachable). Kept inline so
	// distroless images that lack curl/wget can still self-probe.
	if len(os.Args) > 1 && os.Args[1] == "--health-probe" {
		os.Exit(healthProbe())
	}

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
	var signers jwt.SignerHolder
	var certs cert.Holder
	metrics, metricsReg := observability.NewMetrics()
	health := observability.NewHealth()

	if err := bootstrapBundle(ctx, log, bc, &signers, &certs, metrics); err != nil {
		log.Error("bundle bootstrap failed", "error", err)
		os.Exit(1)
	}
	health.SetReady(true)

	// Observability HTTP server on a separate port — never user-facing.
	obsAddr := os.Getenv(envObsAddr)
	if obsAddr == "" {
		obsAddr = defaultObsAddr
	}
	obsMux := http.NewServeMux()
	obsMux.Handle("/metrics", observability.Handler(metricsReg))
	obsMux.HandleFunc("/healthz", health.Healthz)
	obsMux.HandleFunc("/readyz", health.Readyz)
	obsSrv := &http.Server{
		Addr:              obsAddr,
		Handler:           obsMux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		log.Info("observability listening", slog.String("addr", obsAddr))
		if err := obsSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("observability server failed", "error", err)
		}
	}()

	listenAddr := os.Getenv(envListenAddr)
	if listenAddr == "" {
		listenAddr = defaultListenAddr
	}

	ln, err := listener.Listen(ctx, listener.Config{
		ListenAddr:   listenAddr,
		Certificates: &certs,
	})
	if err != nil {
		log.Error("transparent listener failed", "error", err)
		os.Exit(1)
	}
	defer ln.Close()

	log.Info("listening for TPROXY-redirected TLS",
		slog.String("addr", listenAddr),
		slog.Int("apps_with_certs", certs.Get().Size()),
	)

	// Bundle poller — replaces a future PubSub/SSE feed.
	go pollBundle(ctx, log, bc, &signers, &certs, metrics)

	// Build the HTTP handler and serve the TLS listener. ConnContext
	// stuffs each accepted *tls.Conn's LocalAddr() (the original-DST
	// VIP recovered by TPROXY) into the request context — the
	// handler reads it back via handler.LocalAddrKey.
	srv := &http.Server{
		Handler: handler.New(handler.Deps{
			Bundle:   bc,
			Identity: ic,
			Signers:  &signers,
			Certs:    &certs,
			Logger:   log,
			Metrics:  metrics,
		}),
		ConnContext: func(ctx context.Context, c net.Conn) context.Context {
			return context.WithValue(ctx, handler.LocalAddrKey, c.LocalAddr())
		},
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("http.Server.Serve failed", "error", err)
		}
	}()

	<-ctx.Done()
	log.Info("shutting down on signal")
	health.SetReady(false)
	shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancelShutdown()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Warn("graceful shutdown failed", "error", err)
	}
	if err := obsSrv.Shutdown(shutdownCtx); err != nil {
		log.Warn("obs server shutdown failed", "error", err)
	}
}

func healthProbe() int {
	addr := os.Getenv(envObsAddr)
	if addr == "" {
		addr = defaultObsAddr
	}
	client := http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://" + addr + "/readyz")
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		return 0
	}
	return 1
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

func bootstrapBundle(ctx context.Context, log *slog.Logger, bc *bundle.Client, signers *jwt.SignerHolder, certs *cert.Holder, metrics *observability.Metrics) error {
	v, _, err := bc.Fetch(ctx)
	if err != nil {
		return err
	}
	if err := refreshSigner(bc.Current(), signers); err != nil {
		return fmt.Errorf("signer bootstrap: %w", err)
	}
	if err := refreshCerts(bc.Current(), certs); err != nil {
		return fmt.Errorf("cert bootstrap: %w", err)
	}
	metrics.SetBundleVersion(v)
	metrics.SetBundleAgeSeconds(0)
	log.Info("bundle bootstrap complete",
		slog.Int("version", v),
		slog.String("signing_kid", signers.Get().Kid()),
		slog.Int("apps_with_certs", certs.Get().Size()),
	)
	return nil
}

func pollBundle(ctx context.Context, log *slog.Logger, bc *bundle.Client, signers *jwt.SignerHolder, certs *cert.Holder, metrics *observability.Metrics) {
	t := time.NewTicker(bundlePollPeriod)
	defer t.Stop()
	lastFetch := time.Now()

	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			v, changed, err := bc.Fetch(ctx)
			if err != nil {
				log.Warn("bundle poll failed", "error", err)
				metrics.SetBundleAgeSeconds(time.Since(lastFetch).Seconds())
				continue
			}
			lastFetch = time.Now()
			metrics.SetBundleAgeSeconds(0)
			if !changed {
				continue
			}
			if err := refreshSigner(bc.Current(), signers); err != nil {
				log.Warn("signer refresh failed on bundle pivot",
					slog.Int("version", v),
					"error", err)
				continue
			}
			if err := refreshCerts(bc.Current(), certs); err != nil {
				log.Warn("cert refresh failed on bundle pivot",
					slog.Int("version", v),
					"error", err)
				continue
			}
			metrics.SetBundleVersion(v)
			log.Info("bundle updated",
				slog.Int("version", v),
				slog.String("signing_kid", signers.Get().Kid()),
				slog.Int("apps_with_certs", certs.Get().Size()),
			)
		}
	}
}

// refreshSigner parses the SigningKey from the freshly-fetched bundle
// and atomically swaps it into the holder. Returns an error if the
// bundle lacks signing material or the PEM doesn't parse — the
// caller decides whether to keep using the previous signer (bundle
// pivot) or fail bootstrap (first fetch).
func refreshSigner(b *bundle.Bundle, holder *jwt.SignerHolder) error {
	if b == nil {
		return errors.New("bundle is nil")
	}
	if b.SigningKey.Kid == "" || b.SigningKey.PrivatePEM == "" {
		return errors.New("bundle.signing_key missing kid or private_pem")
	}
	s, err := jwt.FromPEM(b.SigningKey.Kid, []byte(b.SigningKey.PrivatePEM))
	if err != nil {
		return err
	}
	holder.Set(s)
	return nil
}

// refreshCerts rebuilds the SNI cert store from the freshly-fetched
// bundle and atomic-swaps it into the holder. Apps without cert
// material (cert_source pending issuance) are silently skipped;
// their TLS handshakes will fail with ErrUnknownHost until certs
// arrive on a later bundle.
func refreshCerts(b *bundle.Bundle, holder *cert.Holder) error {
	if b == nil {
		return errors.New("bundle is nil")
	}
	s, err := cert.FromBundle(b)
	if err != nil {
		return err
	}
	holder.Set(s)
	return nil
}

