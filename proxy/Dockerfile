# syntax=docker/dockerfile:1.6
#
# NexGuard L7 ZTNA Proxy — Linux production image (ADR-007).
#
# Two-stage build:
#   1. `builder` compiles a static binary against Go's standard
#      crypto/network stack — CGO disabled so the runtime image
#      doesn't need glibc.
#   2. `runtime` is gcr.io/distroless/static-debian12 — no shell,
#      no package manager, only CA certs + tzdata. ~20 MB.
#
# Deployment caveats baked into the docker-compose overlay:
#   * network_mode: host  — required for the IP_TRANSPARENT socket
#     to receive TPROXY-redirected packets (the fz_wall chain
#     rewrites packets at the kernel level; userspace must be in
#     the host net namespace to see them).
#   * cap_add: NET_ADMIN  — required for the IP_TRANSPARENT
#     setsockopt call. Without it, listener.Listen() returns EPERM.

# ───────────────────────────────────────────────────────────────
# Stage 1 — builder
# ───────────────────────────────────────────────────────────────
FROM golang:1.26-bookworm AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .

# Static binary, no debug symbols, deterministic build paths.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build \
        -trimpath \
        -ldflags='-s -w -extldflags="-static"' \
        -o /out/nexguard-proxy \
        ./cmd/nexguard-proxy

# ───────────────────────────────────────────────────────────────
# Stage 2 — runtime
# ───────────────────────────────────────────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /out/nexguard-proxy /usr/local/bin/nexguard-proxy

# Default observability port; user-facing TLS port is host-network
# anyway (network_mode: host) so EXPOSE there is a no-op.
EXPOSE 9090

# Non-root execution. NET_ADMIN cap is granted by the compose
# overlay so the runtime user can still IP_TRANSPARENT-bind even
# without uid 0.
USER nonroot:nonroot

ENTRYPOINT ["/usr/local/bin/nexguard-proxy"]
