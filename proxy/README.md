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
├── cmd/nexguard-proxy/   # main entry point
└── internal/
    ├── bundle/           # /internal/bundle.json client + types + cache
    ├── identity/         # /internal/sessions/by_vpn_ip/:ip client + cache
    └── logging/          # slog/JSON house logger
```
