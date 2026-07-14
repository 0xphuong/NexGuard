# L7 ZTNA Architecture

Consolidated design notes for the NexGuard L7 (Layer-7 / hostname-based)
Zero-Trust access plane. This doc gathers what's otherwise scattered
across [`decisions.md`](decisions.md) (ADR-007 → ADR-015), the migration
notes for [v3.0.0](migrations/v3.0.0.md) / [v3.0.1](migrations/v3.0.1.md),
and inline comments in `docker-compose.prod.yml` — so a reader can
understand the whole plane in one pass.

> **Status**: shipped in server v3.0.0. Dormant by default; each
> organisation opts in by flipping `l7_enabled = true` at
> `/settings/l7`. Rollback is one toggle.

## 1. Why L7

The base NexGuard plane authenticates the **user** (OIDC/SAML → VPN
session) and enforces **network reachability** (nftables CIDR + port
rules). It does **not** answer questions like:

- "Alice can reach `hq.example.com` but not `finance.example.com`,
  even though both resolve into the same subnet."
- "Every request to `backend-x` must carry a signed proof of the
  calling user's identity so the backend can log audit events."
- "Some URLs on `hq.example.com` are safe for contractors; others
  require full-time employees."

Those are **hostname- and path-level** decisions. Solving them by
extending nftables would require reversing DNS in the kernel, which
is fragile and blind to hostname → hostname mappings that change
during a session. Instead the L7 plane terminates TLS in userspace,
inspects the destination hostname / path, evaluates a policy bundle,
and (if allowed) reverse-proxies to the backend with a signed
per-request JWT attached.

## 2. Components

```
┌────────────────────────────────────────────────────────────────────┐
│                        NexGuard host                               │
│                                                                    │
│   Internet :443 ──▶ Caddy (public site) ──┐                        │
│                     │                     │                        │
│                     │ /internal/* → 404   │                        │
│                     │ (HARD-BLOCK)        │                        │
│                     │                     │                        │
│                     └──▶ mTLS :13443 ─────┼──▶ Phoenix (nexguard)  │
│                          (internal only)  │       │                │
│                                           │       ├─ /internal/*   │
│                                           │       │  (bundle,      │
│                                           │       │   session,     │
│                                           │       │   JWKS)        │
│                                           │       └─ portal + api  │
│                                           │                        │
│                             ┌─── nftables (fz_wall) ───┐           │
│   VPN client :51820/udp ────▶ TPROXY chain (l7_prerouting)         │
│                             │       │                              │
│                             │       ▼                              │
│                             └─▶ nexguard-proxy :8443 ──▶ backend   │
│                                     │                              │
│                                     │ mTLS                         │
│                                     └─▶ Caddy :13443 (fetch bundle)│
│                                                                    │
│                             CoreDNS :53 (in nexguard netns)        │
│                                     │                              │
│                             VPN client dig backend.corp ───────────┤
└────────────────────────────────────────────────────────────────────┘
```

| Component | Container | Purpose |
|---|---|---|
| **Phoenix** | `nexguard` | Serves `/internal/bundle.json`, `/internal/sessions/*`, and `/.well-known/jwks.json` under a mTLS-gated Caddy site. |
| **Caddy** | `caddy` | Dual listener: `:443` public portal (with `/internal/*` hard-blocked) + `:13443` internal mTLS site. Auto-TLS via Let's Encrypt for the public listener; static CA-signed cert for the mTLS listener. |
| **nexguard-proxy** | `nexguard-proxy` (opt-in) | Custom Go binary (~5 KLOC). IP_TRANSPARENT TLS listener at `127.0.0.1:8443` inside the nexguard netns; consumes the signed bundle, signs per-request RS256 JWTs, reverse-proxies to backends. Distroless image (~20 MB). |
| **CoreDNS** | `nexguard-coredns` (opt-in) | Resolves internal application hostnames for VPN clients. Corefile is DB-backed by Phoenix (`/etc/nexguard/Corefile.generated`, reload 1s). Also NXDOMAINs the `.local/.lan/.home/.internal/.corp` noise so it never reaches upstream DNS. |

Design decisions behind each piece:

- **Custom Go proxy**, not Pomerium / Envoy — [ADR-007](decisions.md#adr-007--l7-proxy-implementation-custom-go-binary).
- **Inline rule DSL** (Pomerium-PPL style), OPA deferred — [ADR-008](decisions.md#adr-008--policy-language-inline-rules-pomerium-ppl-style-defer-opa).
- **TLS termination** (not passthrough) — [ADR-009](decisions.md#adr-009--tls-strategy-terminate-by-default-passthrough-deferred-to-v2).
- **Identity via signed JWT header** — [ADR-010](decisions.md#adr-010--identity-propagation-jwt-signed-headers-iap-pattern).
- **Internal CA**: script-managed (`l7-rotate-proxy-cert.sh`); the smallstep `step-ca` ACME path in [ADR-011](decisions.md#adr-011--internal-ca-smallstep-step-ca-acme-managed) is deferred — the current script covers all needs for single-gateway deployments.
- **CoreDNS with hosts plugin**, identity-agnostic — [ADR-012](decisions.md#adr-012--dns-coredns-with-hosts-plugin-identity-agnostic).
- **Bundle over pull + PubSub** — [ADR-013](decisions.md#adr-013--policy-distribution-phoenix-pulled-json-bundle--pubsub-invalidation).
- **L7 is opt-in per app, scoped to internal domains** — [ADR-014](decisions.md#adr-014--l7-enforcement-is-opt-in-per-managed-app-scoped-to-internal-domains-only).
- **Shared TLS cert library for backends** — [ADR-015](decisions.md#adr-015--tls-certificate-library-shared-replace-in-place-san-matched).

## 3. Data flow — a single L7 request

Trace a request from a VPN client to a backend when the org has
`l7_enabled = true` and the target is an L7-managed application:

1. **VPN client sends packet** to `backend.corp` (a hostname declared
   in the admin UI as an L7 application). WG encrypts, sends to the
   NexGuard gateway UDP :51820.

2. **Kernel decrypts** the WG packet and hands it to netfilter. The
   base `nexguard` chain would forward it to the destination IP;
   the `l7_prerouting` chain (installed only when `l7_enabled=true`)
   intercepts and TPROXY-diverts it to `127.0.0.1:8443` inside the
   nexguard container's netns.

3. **nexguard-proxy accepts** on its `IP_TRANSPARENT` socket. Reads
   `SO_ORIGINAL_DST` to recover the original destination IP.

4. **Proxy identifies the caller** via `SO_ORIGINAL_DST`'s source IP
   (that's the VPN-assigned IP). Looks up
   `/internal/sessions/by_vpn_ip/:ip` on Phoenix (30s TTL cache) —
   returns `{user_id, email, groups, session_expires_at, ...}`.

5. **Proxy terminates TLS**. Fetches the SNI-matched cert from the
   in-memory store (loaded from `/internal/bundle.json` — see
   ADR-015 for the shared cert library semantics).

6. **Policy evaluation**. `bundle.rules` (loaded from
   `/internal/bundle.json`, refreshed via long-poll `?since=` and
   PubSub) is walked first-match-wins against `(hostname, path,
   method, identity)`. If no rule matches or top match is `deny` →
   `403 Forbidden`.

7. **Proxy signs a per-request JWT** using the RS256 private key
   loaded from the bundle. Claims: `iss=nexguard-proxy`,
   `aud=<app_uuid>`, `sub=<user_email>`, `groups=[...]`, `jti`,
   `nbf`, `exp` (60s ahead). Backends verify with the JWKS
   fetched from `<external_url>/.well-known/jwks.json` (public,
   no auth).

8. **Proxy reverse-proxies** to the backend hostname (which was
   resolved via CoreDNS → hosts plugin → internal IP mapping).
   Outbound TLS is pinned to TLS 1.2+ with a modern cipher list.
   `X-Forwarded-*` headers are stripped and re-added canonically.

9. **Backend receives the request** with the signed JWT in
   `Authorization: Bearer <jwt>` (configurable header name per
   application). Verifies the signature, checks `aud` matches
   its own app UUID, checks `nbf`/`exp`, then processes.

Response flows back through the proxy → TCP RST/FIN → VPN client
sees the response as if it had connected directly. From the client's
perspective, nothing is different from a plain WG tunnel — the
proxy is transparent.

## 4. Cert lifecycle

Three certs, one CA, one script:

```
              ┌────────────────────┐
              │   internal-ca.pem  │  self-signed root, 10-year validity
              │   internal-ca.key  │  (mode 0600, never leaves the host)
              └─────────┬──────────┘
                        │ signs
             ┌──────────┼──────────┐
             ▼                     ▼
   internal-server.pem       proxy.pem
   internal-server.key       proxy.key
   (1-year validity)         (1-year validity)
             │                     │
             ▼                     ▼
   Presented by Caddy       Presented by proxy
   on :13443                 as CLIENT to :13443
```

**Script**: `scripts/l7-rotate-proxy-cert.sh` (bundled in both the
server repo and the `nexguard-install` repo). Idempotent:

- **First run**: creates the CA + both leaves.
- **Re-run**: rotates the two leaves; CA preserved. Old leaves
  archived under `$NEXGUARD_CERTS_DIR/archive/<timestamp>/` in case
  a recently-issued JWT / in-flight TLS handshake needs to verify
  against the previous material.
- **`--reset-ca`**: rotate the CA too. Every previously-issued proxy
  cert becomes invalid; Caddy needs a restart afterward.

**Cadence**: leaves annually (365-day validity), CA on breach or
role transitions. There's no automatic reminder yet — put it on
the ops calendar.

**File owner**: certs are chmod 0640 owned by `uid=65532`
(distroless nonroot). The proxy container runs as `uid=0` inside
its namespace + `cap_add: DAC_READ_SEARCH` to read them without
needing full DAC_OVERRIDE. See [`proxy/README.md`](../proxy/README.md)
for why root-with-narrow-caps beats non-root without them (the
distroless nonroot user can't receive cap_add'ed capabilities).

## 5. Caddy dual-listener design

This is the piece not documented anywhere except inline comments
in `docker-compose.prod.yml`. Detailed here so future readers don't
have to reconstruct it.

### 5.1 Two listeners, one Caddy

| Listener | Purpose | Auth | Loaded when |
|---|---|---|---|
| `:443` (public portal) | User + admin UI, native client APIs | Session cookie / bearer token / mTLS at app layer | Always |
| `:13443` (internal mTLS) | `nexguard-proxy` fetching bundle / sessions / JWKS | Client-cert mTLS | Only when all three cert files exist on disk |

Splitting into two ports means:

- The public listener needs Let's Encrypt (auto-renewing, world-visible cert).
- The internal listener needs a **static internally-issued cert**
  (long-lived, not published to any CT log — private trust anchor).

Both listeners reverse-proxy to the **same Phoenix backend**
(`172.25.0.100:13000`) but different code paths:

- Public: everything except `/internal/*`.
- Internal: `/internal/bundle.json`, `/internal/sessions/*`,
  `/.well-known/jwks.json`.

### 5.2 Fail-safe boot pattern

The Caddyfile is **built at container-start by a shell wrapper**
that checks `-f` on each cert file. This makes the container:

- ✅ Boot cleanly on a **fresh install** where the operator hasn't
  run the cert-rotate script yet (Caddyfile has only the public
  site — no reference to missing files → Caddy doesn't error out).
- ✅ Boot cleanly on a **pre-L7 upgrade** where operators are
  upgrading from < v3.0.0 and haven't set up mTLS yet.
- ✅ Automatically pick up the `:13443` listener the first time
  it's restarted after the cert-rotate script has run.

Pseudocode (see `docker-compose.prod.yml` and the mirrored
`nexguard-install/docker/docker-compose.yml` for the actual
implementation):

```bash
if all three cert files exist:
  emit `{ servers :13443 { strict_sni_host insecure_off } }` (global block)
else:
  truncate Caddyfile

# always emit the public portal site with the hard-block:
emit `${EXTERNAL_URL} { @internal path /internal/* /internal ; respond @internal 404 ; reverse_proxy ... }`

if all three cert files exist:
  emit `:13443 { tls ... client_auth { mode require_and_verify ... } ; reverse_proxy ... }`

caddy run
```

The Ansible install path (`nexguard-install/ansible/roles/proxy/`)
uses the same pattern but implements the file-existence check via
Ansible `stat` + Jinja2 conditional blocks in `Caddyfile.j2` —
functionally equivalent but declarative.

### 5.3 Why `strict_sni_host insecure_off`

Caddy's default `strict_sni_host = on` rejects any request whose
`Host` header doesn't match the SNI-derived server identity. For
the public portal (name-based routing over Let's Encrypt certs)
that's the right default.

On `:13443`, the L7 proxy connects via **the docker bridge gateway
IP** (`https://172.25.0.1:13443`) — not a hostname. Per
**RFC 6066 §3**, TLS clients **MUST NOT send SNI when the server
identity is an IP literal**. So Caddy sees Host = `172.25.0.1:13443`
but no SNI to match against → 421 "Misdirected Request".

Disabling `strict_sni_host` on that one listener is safe because
`:13443` has **exactly one mTLS-gated site**. There's no
Host-based site selection to bypass; the only way in is with a
valid client cert signed by `internal-ca.pem`.

### 5.4 Defense-in-depth on `/internal/*`

Three layers gate the secret-bearing endpoints:

1. **Caddy `:443` returns 404** on `/internal/*`, before the request
   ever reaches Phoenix. Even a compromised Let's Encrypt cert
   can't leak the bundle from the public listener.
2. **Caddy `:13443` requires client-cert mTLS**. Without a cert
   signed by the internal CA, TLS handshake fails before HTTP.
3. **Phoenix's own controller checks the mTLS peer identity**
   (via the `X-SSL-Client-Verify` header injected by Caddy) and
   401s if it's not `SUCCESS`. Redundant with layer 2 but cheap.

Bypassing all three requires compromising the internal CA private
key on the NexGuard host itself — at which point the attacker
already owns the box.

## 6. Bundle distribution

The **bundle** is Phoenix's compiled, signed representation of the
L7 policy state. Contents:

```json
{
  "generation": 42,
  "issued_at": "2026-07-13T10:15:30Z",
  "signing_key": {
    "kid": "l7-signing-2026-07",
    "private_pem": "-----BEGIN RSA PRIVATE KEY-----..."
  },
  "applications": [
    {
      "id": "a1b2c3...",
      "hostnames": ["hq.example.com"],
      "backend": {"scheme": "https", "host": "10.0.100.5", "port": 8443},
      "cert_id": "c1d2e3...",
      "cert_pem": "-----BEGIN CERTIFICATE-----...",
      "key_pem": "-----BEGIN PRIVATE KEY-----..."
    }
  ],
  "rules": [
    {
      "app_id": "a1b2c3...",
      "match": {"path_prefix": "/api"},
      "allow_groups": ["engineering"]
    }
  ]
}
```

**Delivery**:

- **Long-poll**: proxy does `GET /internal/bundle.json?since=<generation>`.
  Phoenix holds the connection for up to 30s; returns immediately
  when the bundle rev advances (any UI edit → `nexguard:l7:bundle`
  PubSub → holds released).
- **ETag fallback**: `If-None-Match` on the initial fetch after
  restart so a proxy restart doesn't redownload if nothing changed.
- **Last-Known-Good ring**: Phoenix keeps the last 3 bundles in
  ETS. If the compile crashes (e.g. missing cert on a fresh app),
  the ring serves the previous known-good so the fleet doesn't
  degrade.

Details in [ADR-013](decisions.md#adr-013--policy-distribution-phoenix-pulled-json-bundle--pubsub-invalidation).

## 7. Session lookup

Distinct endpoint because bundle contents rarely change but session
state changes on every VPN connect/disconnect/MFA.

- **`GET /internal/sessions/by_vpn_ip/:ip`** — returns the identity
  payload for the VPN-assigned IP.
- **Cache**: proxy holds each `(vpn_ip → identity)` for 30s with
  a lazy refresh. Balances "session revocation propagates fast"
  against "one lookup per request would 10× Phoenix load".
- **ETag**: identical to bundle — 304 saves 90%+ of the payload
  when nothing changed.

## 8. Activation & rollback

**Activation** (per organisation):

1. Operator runs `l7-rotate-proxy-cert.sh` to provision the mTLS
   material.
2. Restart Caddy (or re-render Caddyfile via Ansible + reload).
3. `docker compose -f docker-compose.prod.yml -f docker-compose.proxy.yml
   up -d` (or via Ansible role `l7=true`) — brings up the proxy
   daemon + CoreDNS. Both come up **dormant**: the proxy
   healthchecks, fetches an (empty) bundle, waits.
4. Admin opens `/settings/l7` in the portal → toggles
   `l7_enabled = true`.
5. The toggle triggers `FzWall.CLI.Helpers.Tproxy` to install the
   `l7_prerouting` nftables chain. From this instant, packets to
   declared L7-managed hostnames divert to the proxy.

**Rollback**: admin flips `l7_enabled = false`. The chain is
removed atomically; packets go back to the plain WG/nftables path.
No container restart, no data loss.

The proxy + CoreDNS containers keep running when `l7_enabled` is
false — they're inert without the nftables divert. Operators
running short of RAM can `docker compose ... rm proxy coredns` to
reclaim ~30 MB, but the standard advice is to leave them up so
re-enabling is a one-toggle operation.

## 9. Install paths

The L7 plane is available through both installation methods:

| Path | Location | Notes |
|---|---|---|
| **Source-repo `docker-compose.proxy.yml`** | `nexguard/docker-compose.proxy.yml` | Builds `proxy/` from source. Preferred for dev + operators tracking `main`. |
| **`nexguard-install` compose overlay** | `nexguard-install/docker/docker-compose.l7.yml` | Uses the published `docker.io/binhphuong/nexguard-proxy:latest` image. Preferred for standard customer installs. Bundled `l7-rotate-proxy-cert.sh` for operators who don't clone the source. |
| **`nexguard-install` Ansible role** | `nexguard-install/ansible/roles/l7/` | Production multi-host, secrets via Vault. The `proxy` role's Caddyfile template auto-detects L7 certs via Ansible `stat`. |

All three paths use the **same** fail-safe Caddy design described
in §5 — a fresh install where the operator hasn't yet run
`l7-rotate-proxy-cert.sh` boots the public portal only, and L7
activation later is a re-render + reload, not a re-provision.

## 10. Migration references

- [v3.0.0 migration notes](migrations/v3.0.0.md) — first release
  with the proxy daemon; introduces the `:13443` listener, the
  cert rotation script, and `/internal/*` hard-block.
- [v3.0.1 migration notes](migrations/v3.0.1.md) — hardening pass:
  `X-Forwarded-*` stripping, path normalisation, JWT `nbf`, log
  redaction, PEM zeroing.

## 11. Future work

Explicitly deferred from ADR-007 → ADR-015 and worth flagging so
they're on the radar:

- **Passthrough TLS** for backends that need end-to-end encryption
  without proxy termination (ADR-009 defers to v2).
- **smallstep step-ca** for ACME-managed internal CA (ADR-011).
  Current script covers single-gateway scale; step-ca becomes
  worth it around 5+ gateways or when audit requirements demand
  cert transparency for internal certs.
- **OPA** or Rego-based policy language (ADR-008). Inline PPL-style
  is adequate up to ~20 rules per org.
- **Multi-gateway** — the proxy is single-instance-per-host today.
  Sharding by hostname or by client subnet is possible but not
  needed at current scale.
- **ext_authz gRPC interface** for backends that want to consume
  the identity decision without HTTP header parsing (ADR-007's
  future migration path).
