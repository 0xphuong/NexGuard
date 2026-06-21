# NexGuard L7 ZTNA Proxy

Linux transparent proxy that terminates per-application TLS for L7 ZTNA
enforcement (ADR-007 → ADR-014). Lives as a subdirectory of the main
NexGuard repo; ships as part of the `v3.0.0` release line.

> **Status: under construction (L7-D).** This binary does not yet
> intercept traffic. The bundle + identity HTTP clients work; the
> TLS listener, TPROXY socket, policy evaluator, JWT signer, and
> reverse proxy land in follow-up commits. See `task.md` →
> L7-D summary checklist for the full task list.

## Build

```bash
cd proxy/
go build -o ./bin/nexguard-proxy ./cmd/nexguard-proxy
```

Requires Go ≥ 1.22. Linux is the deployment target; macOS/Windows
work for local dev (build + unit tests) but the TPROXY socket
(`IP_TRANSPARENT`, `SO_ORIGINAL_DST`) lives behind Linux-only
syscalls and will be stubbed out on non-Linux builds when it lands.

## Run

```bash
NEXGUARD_SERVER_URL=https://nexguard.example.com \
NEXGUARD_PROXY_LOG_LEVEL=info \
  ./bin/nexguard-proxy
```

## Test

```bash
go test ./...
```

## Layout

```
proxy/
├── cmd/nexguard-proxy/    # main entry point + --health-probe subcommand
└── internal/
    ├── bundle/            # /internal/bundle.json client (atomic-swap + ETag/?since)
    ├── identity/          # /internal/sessions/by_vpn_ip/:ip client (30 s TTL cache)
    ├── jwt/               # RS256 signer (stdlib crypto/rsa, no third-party JWT lib)
    ├── cert/              # SNI cert store (host → *tls.Certificate, atomic swap)
    ├── listener/          # IP_TRANSPARENT TCP listener + TLS wrap (Linux-only)
    ├── policy/            # Decide(bundle, app, identity, request) → Allow/Deny
    ├── handler/           # request hot path + structured per-request log
    ├── observability/     # Prometheus metrics + /healthz + /readyz
    └── logging/           # slog/JSON house logger
```

## Docker

Production image (distroless static, ~20 MB):

```bash
cd proxy/
docker build -t nexguard-proxy:dev .
```

Deployed via the opt-in `docker-compose.proxy.yml` overlay in the repo
root — see `docs/migrations/v3.0.0.md` (lands in Phase 9) for the
end-to-end runbook.

## Environment

| Var | Required | Default | Purpose |
|---|---|---|---|
| `NEXGUARD_SERVER_URL` | yes | — | Portal URL, e.g. `https://nexguard.example.com` |
| `NEXGUARD_PROXY_LISTEN` | no | `127.0.0.1:8443` | User-facing TLS listener (TPROXY destination) |
| `NEXGUARD_PROXY_OBS_LISTEN` | no | `127.0.0.1:9090` | Observability port (`/metrics`, `/healthz`, `/readyz`) |
| `NEXGUARD_PROXY_LOG_LEVEL` | no | `info` | `debug` / `info` / `warn` / `error` |
