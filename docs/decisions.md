# Architecture Decision Records — NexGuard server

This file collects architectural decisions specific to the NexGuard server
and gateway. Client-side ADRs live in [`nexguard-connect/docs/decisions.md`](https://github.com/0xphuong/nexguard-connect/blob/main/docs/decisions.md).

For the L7 architecture overview these decisions implement, see
[`nexguard-connect/SPEC.md` §8](https://github.com/0xphuong/nexguard-connect/blob/main/SPEC.md#8-gateway-l7-architecture)
and the server-side operator-facing walkthrough in
[`l7-architecture.md`](l7-architecture.md) — the consolidated doc
that ties together ADR-007 → ADR-015, the v3.0.0 / v3.0.1 migration
notes, and the Caddy dual-listener design that would otherwise live
only in `docker-compose.prod.yml` inline comments.

The provisional umbrella decision (ADR-006) lives in that repo; the
records below (ADR-007 → ADR-013) refine it into concrete commitments
before implementation begins.

---

## ADR-007 — L7 proxy implementation: Custom Go binary

**Date**: 2026-06-19
**Status**: ✅ Accepted

**Decision**: Implement the L7 transparent proxy as a **custom Go binary**
maintained in this repo (or as a sibling repo), not as a fork of an
existing proxy.

**Rationale**:
- Full control over the Linux-specific bits the design depends on:
  `IP_TRANSPARENT` socket option, `SO_ORIGINAL_DST` lookup, integration
  with the existing nftables `fz_wall` chain.
- NexGuard's identity model is **VPN-IP-anchored** (`vpn_ip → user`), not
  cookie / OIDC token like Pomerium. Bending an existing proxy to this
  model is more work than starting fresh.
- Estimated 3-5 KLOC Go — manageable surface to audit.

**Alternatives rejected**:
- **Fork Pomerium**: drags in OIDC connectors, JWKS rotation, browser
  session machinery NexGuard doesn't need; maintenance burden of
  upstream tracking outweighs the head start.
- **Envoy + ext_authz**: xDS config overhead, requires running two
  services (Envoy + auth service), heavier resource footprint, steep
  operational learning curve for admins of small self-hosted deployments.

**Future migration path**: the Go proxy will expose an internal
`Authorize(request) → decision` interface separable from the data
plane. If we later need ext_authz interop (see ADR-009), the same
function can be re-exposed over gRPC.

**Consequences**:
- We own the proxy security posture — bake in TLS 1.3 minimum, pin
  modern ciphers, run security-review before each release.
- Performance / scaling work is on us. Acceptable for self-hosted
  single-gateway scale (sub-10k req/s). Revisit if NexGuard ever runs
  multi-gateway / SaaS.

---

## ADR-008 — Policy language: inline rules (Pomerium-PPL style), defer OPA

**Date**: 2026-06-19
**Status**: ✅ Accepted

**Decision**: Express L7 policy as **inline rules stored as JSONB** on
the `applications` table. Rules evaluate **first-match, default-deny**
with explicit fields:

```jsonc
{
  "required_groups": ["wiki-readers"],
  "l7_rules": [
    { "method": ["GET", "POST"], "path_prefix": "/api/", "action": "allow" },
    { "method": ["DELETE"], "path_prefix": "/admin/", "action": "allow",
      "require_groups": ["wiki-admins"], "require_mfa_age_seconds": 300 },
    { "action": "deny" }
  ],
  "inject_headers": { "X-NexGuard-User": "{user.email}" },
  "strip_headers": ["X-NexGuard-Spoof-Attempt"]
}
```

OPA Rego support is **explicitly deferred**. The proxy will treat the
policy engine as pluggable — `policy_engine: "rules" | "rego"` per app —
so a Rego backend can be added later without re-architecting.

**Rationale**:
- The four enforcement primitives (group, method, path, MFA freshness)
  cover ~80% of expected use cases.
- Structured JSON rules are **table-editable** in the admin UI; Rego is
  string-based and forces a code-editor UX.
- Schema validation is straightforward with JSON Schema; Rego policy
  validation needs a Rego interpreter at compile time.
- Defers an entire dependency (`open-policy-agent`) we don't need yet.

**Alternatives rejected**:
- **OPA Rego from day 1**: more powerful, but admin tooling becomes
  text-editor-driven, learning curve for first-time admins is steep.
- **AWS Cedar**: ecosystem outside AWS still immature; revisit in 12-18
  months if Cedar adoption grows.
- **CEL (Google IAP style)**: less expressive than Rego, no clear win
  over inline rules either.

**Consequences**:
- Complex policies that don't fit the rules schema will require
  workarounds (multiple rules, splitting apps) until Rego support
  arrives.
- We need a JSON Schema published alongside the proxy and validated
  before persisting rules in the DB.

---

## ADR-009 — TLS strategy: terminate by default, passthrough deferred to v2

**Date**: 2026-06-19
**Status**: ✅ Accepted

**Decision**: The L7 proxy terminates TLS using certs issued by the
NexGuard internal CA (see ADR-011) for every managed app. **Passthrough
mode** (SNI-routed, no decryption) is **planned** as a per-app opt-in
`tls_mode: "passthrough"` but **deferred to v2** — v1 ships terminate
only.

**Rationale**:
- L7 enforcement (method, path, header inject) requires decrypted HTTP;
  terminate is mandatory for the headline feature.
- Passthrough is a useful escape hatch for legacy backends that can't
  trust the internal CA, but those are edge cases — shipping it later
  doesn't block the 90% case.
- Single TLS mode in v1 simplifies the proxy's listener, cert hot-reload,
  and admin UI.

**Alternatives rejected**:
- **TLS bridge (terminate + cleartext forward)**: unsafe if proxy and
  backend cross zones.
- **Passthrough as default**: defeats the entire L7 IAP purpose; we
  picked terminate because Pomerium / IAP / Zscaler do, for good reason.

**Consequences**:
- Every device that uses managed apps must trust the NexGuard internal
  CA root. Provisioning is the NexGuard Connect client's job (auto-install
  via `Security.framework`), with MDM as the enterprise fallback.
- Legacy apps that can't tolerate intermediate TLS termination must wait
  for the v2 passthrough mode or be deployed behind a separate gateway.

---

## ADR-010 — Identity propagation: JWT-signed headers (IAP pattern)

**Date**: 2026-06-19
**Status**: ✅ Accepted

**Decision**: After authorization succeeds, the proxy injects identity
headers AND a signed JWT into the upstream request:

```http
X-NexGuard-User:           bob@example.com
X-NexGuard-User-Id:        user-uuid
X-NexGuard-Groups:         engineering,wiki-readers
X-NexGuard-Mfa-Age:        120
X-NexGuard-Device-Id:      device-uuid
X-NexGuard-Identity-Jwt:   <RS256-signed JWT, claims mirror the above>
```

The proxy **strips** any inbound `X-NexGuard-*` header before injecting
fresh values. Signing key is RS256, rotated annually; backends verify
via the gateway's JWKS endpoint at `/.well-known/jwks.json`.

**Rationale**:
- Without the JWT, plain headers are spoofable if a backend is ever
  reachable outside the gateway path.
- The JWT pattern is industry-standard (Google IAP's
  `X-Goog-IAP-JWT-Assertion`), familiar to any backend dev.
- Backends that don't care can ignore the JWT and read plain headers;
  security-conscious apps verify the signature.

**Alternatives rejected**:
- **Plain headers only**: trivially spoofable.
- **mTLS to backend with device cert**: heavier ops (every backend
  needs to verify a mesh cert), revisit in v2 for highest-security apps.

**Consequences**:
- Gateway must expose a JWKS endpoint and rotate signing keys.
- We document the JWT claims schema as part of the public NexGuard
  integration spec.

---

## ADR-014 — L7 enforcement is opt-in per managed app, scoped to internal domains only

**Date**: 2026-06-19
**Status**: ✅ Accepted

**Decision**: The L7 transparent proxy enforces policy **only** on
traffic destined for **explicitly declared internal-domain
applications**. Public-internet traffic — even when it traverses the
NexGuard gateway in full-tunnel mode — bypasses the L7 proxy entirely
and continues to be filtered solely by the existing L3 / L4 nftables
rules.

Two switches control L7:

1. **Per-org feature toggle** (`org_settings.l7_enabled`): when
   `false`, no traffic is steered to the proxy regardless of any
   per-app config; the entire L7 subsystem is dormant.

2. **Per-app declaration** (`applications` row with
   `tls_mode = 'terminate'`, `enabled = true`): an admin must
   explicitly declare a hostname + backend + cert + group/L7 rules
   for each app that should sit behind the proxy.

**Routing logic** (when both switches are on):

```
Client DNS query
  ├─ hostname in declared apps  → CoreDNS returns VIP (10.99.0.0/16)
  └─ everything else            → upstream DNS, real public IP

Packet at gateway (any dst):
  ├─ dst IP ∈ 10.99.0.0/16     → TPROXY → L7 proxy
  └─ dst IP ∉ 10.99.0.0/16     → existing L3/L4 forward + SNAT
                                  (Twitter, Google, customer SaaS, etc.)
```

**Rationale**:
- ZTNA is meant for **the apps you own**. Public services
  (Google Workspace, GitHub.com, etc.) already enforce their own
  authn/z; intercepting them adds zero value and breaks cert
  pinning / HSTS / public CA trust assumptions.
- Selective interception matches industry pattern: Pomerium, Google
  IAP, Cloudflare Access, Zscaler ZPA all enforce **per declared
  app**, not "everything that flows through us".
- Operationally lower risk: a bug in the proxy or a CA outage only
  affects declared internal apps, not the user's entire internet.
- Cleaner UX: admins reason about "apps I'm publishing", not "every
  hostname in the universe".

**Per-app cert sources** (decided alongside ADR-011):
- `cert_source: "upload"` — admin uploads existing cert + key
  (e.g. a Let's Encrypt cert for a real public hostname like
  `gitlab.example.com`). No internal CA trust needed on clients.
- `cert_source: "step_ca"` — NexGuard's internal CA issues the cert
  (e.g. for `gitlab.internal.lan`). Requires the client device to
  trust the internal CA root (NexGuard Connect auto-installs).

Both sources are first-class; admins choose per app.

**Alternatives rejected**:
- **Blanket L7 MITM of all HTTPS** — was the implicit model in early
  drafts. Breaks public sites (cert pinning), needs root CA installed
  to intercept every site, indistinguishable from a corporate
  surveillance proxy, scales poorly. Hard reject.
- **L7 enforced for all hostnames within configured LAN CIDR** — too
  coarse; an internal-CIDR backend might serve multiple hostnames,
  not all of which need L7 inspection.

**Consequences**:
- Admin UI must include a "Managed Applications" section where each
  app is declared with hostname, backend URL, cert source, required
  groups, and L7 rules.
- CoreDNS hosts file is rebuilt from the `applications` table on
  every change; non-declared hostnames pass through to upstream
  DNS unmodified.
- The proxy refuses to serve any hostname that isn't in the bundle —
  unknown VIPs return 404 with `X-NexGuard-Reason: unknown-app`,
  not a falsified cert.
- The per-org toggle gives operators a kill switch — if the L7
  subsystem misbehaves, flipping `l7_enabled = false` reverts to
  the previously-shipping L3/L4-only enforcement (zero downtime
  via PubSub broadcast).

**Cross-references**: refines and supersedes the implicit
"everything goes through the proxy" assumption in
[`nexguard-connect/SPEC.md` §8](https://github.com/0xphuong/nexguard-connect/blob/main/SPEC.md#8-gateway-l7-architecture)
and [ADR-006](https://github.com/0xphuong/nexguard-connect/blob/main/docs/decisions.md#adr-006).
The architecture in §8 is correct for declared apps; SPEC §8 should
be updated to make the opt-in nature explicit (tracked under L7-A
in `task.md`).

---

## ADR-011 — Internal CA: smallstep `step-ca`, ACME-managed

**Date**: 2026-06-19
**Status**: ✅ Accepted

**Decision**: Run **smallstep `step-ca`** as a sidecar on the gateway
host. Hierarchy:

- **Root CA**: 10-year validity, offline-backed up
- **Intermediate**: 5-year, online for issuance
- **Leaf certs** for managed apps (`*.internal.example.com`): 90-day,
  auto-renewed via ACME by the proxy

Provisioner: JWT (Phoenix issues short-lived tokens) — `step-ca`
authorizes the proxy to request certs for hostnames the proxy is
configured to serve.

**Cert source is per-app, not gateway-wide** (see also ADR-014):
- `cert_source: "upload"` — admin uploads cert + key (typical for
  declared apps with real public hostnames + Let's Encrypt cert).
  No internal CA touched. No client-side CA trust needed.
- `cert_source: "step_ca"` — `step-ca` issues the leaf cert (typical
  for `.internal` / `.lan` hostnames). Requires devices to trust the
  internal CA root.

Many small deployments will only use `cert_source: "upload"` with
real-DNS certs and may never deploy `step-ca` at all. `step-ca` is
**provisioned only when at least one app uses `cert_source: "step_ca"`**.

**Rationale**:
- Mature, well-documented, single Go binary.
- ACME-compatible — the proxy can renew with any ACME client (or use
  `step` directly).
- Far less operational burden than a hand-rolled OpenSSL setup; less
  infrastructure than Vault PKI.

**Alternatives rejected**:
- **Hand-rolled OpenSSL**: no rotation automation, error-prone.
- **HashiCorp Vault PKI**: overkill for a single-purpose CA, requires
  running Vault.
- **cert-manager**: assumes Kubernetes, which we are not.

**Consequences**:
- Operators must safeguard the root CA private key (offline / HSM in
  serious deployments).
- Backend services that need to trust the proxy (when proxy initiates
  outbound TLS) can either use the public CA chain to the backend's
  real cert, or trust the NexGuard intermediate.

---

## ADR-012 — DNS: CoreDNS with hosts plugin, identity-agnostic

**Date**: 2026-06-19
**Status**: ✅ Accepted

**Decision**: Resolve managed-app hostnames to their virtual IPs using
**CoreDNS** with the `hosts` plugin. DNS is **identity-agnostic** —
every user receives the same VIP for the same hostname. Policy
enforcement happens at the proxy, not at DNS.

**Hosts file** is rebuilt by Phoenix whenever an app is published,
unpublished, or has its VIP changed; CoreDNS picks up changes via the
`reload` plugin (1-second watch).

**Selective override** (per ADR-014): the hosts file contains **only
the declared internal-domain hostnames**. Everything else (Google,
GitHub, customer SaaS) passes through to upstream DNS (`1.1.1.1` /
`8.8.8.8`) and resolves to its real public IP. CoreDNS never lies
about a hostname that isn't in the bundle.

**Rationale**:
- DNS is a poor place to enforce policy: queries don't carry identity,
  client/OS caching is unreliable, NXDOMAIN gives no useful error.
- CoreDNS is the de facto modern OSS DNS server (used by Kubernetes,
  among others); its plugin model is straightforward.
- Centralising the VIP table in `/etc/nexguard/internal-hosts` keeps
  the resolution path obvious and auditable.

**Alternatives rejected**:
- **Identity-aware DNS** (different result per user): defeats DNS
  caching, requires a custom DNS implementation, leaks app existence
  via NXDOMAIN/no-answer behaviour.
- **Unbound / dnsmasq / PowerDNS**: less ergonomic for our small,
  flat host-mapping use case.

**Consequences**:
- Admins must be aware that knowing a hostname → VIP mapping does NOT
  grant access; the proxy still enforces. (Note this in admin
  documentation.)
- Future managed-app additions must trigger a Phoenix-side hosts-file
  regenerate.

---

## ADR-013 — Policy distribution: Phoenix-pulled JSON bundle + PubSub invalidation

**Date**: 2026-06-19
**Status**: ✅ Accepted

**Decision**: The proxy holds a **compiled policy bundle** in memory.
Phoenix exposes:

- `GET /internal/bundle.json` — full bundle (apps + groups + JWKS),
  mTLS-protected, signed
- `GET /internal/sessions/by_vpn_ip/{ip}` — single-user identity
  payload (cached in proxy with 30s TTL)

Updates propagate via **Phoenix.PubSub broadcasts**:

- `{:bundle_updated, version}` — proxy re-fetches bundle, atomic-swaps
  pointer
- `{:identity_updated, vpn_ip}` — proxy invalidates the matching
  identity cache entry

The proxy keeps the last known-good bundle and rejects swaps that fail
to validate.

**Rationale**:
- Decouples the proxy from the database schema (no direct Postgrex
  reads in the proxy).
- Atomic swap means the proxy is never partially-configured.
- PubSub is already part of the Phoenix stack — no new infrastructure.
- Last-known-good fallback is critical for outage resilience: a
  Phoenix restart or DB issue must not blackhole all traffic.

**Alternatives rejected**:
- **Proxy reads DB directly**: couples proxy to schema, requires DB
  credentials in proxy, makes upgrades brittle.
- **Push via gRPC stream (Envoy xDS-style)**: more complex than needed
  for a single gateway; revisit if NexGuard ever runs multi-gateway.
- **OPA bundle service**: revisit if/when we adopt Rego (ADR-008
  defers it).

**Consequences**:
- Bundle compile time grows with org size; if it ever crosses ~200ms,
  switch to incremental compile (diff changed apps only).
- We must document the signed bundle format so future proxy
  implementations (or third-party reimplementations) can interop.

---

## ADR-015 — TLS certificate library: shared, replace-in-place, SAN-matched

**Date**: 2026-06-24
**Status**: ✅ Accepted

**Decision**: Introduce a **shared TLS certificate library** as a third
`cert_source` value (alongside `:upload` and `:step_ca` from ADR-011).
Admins upload each wildcard or multi-SAN cert **once** to
`/settings/certificates`, and L7 apps reference it by FK
(`tls_cert_id`) — or leave the FK NULL to let the resolver **auto-match
by hostname** against the library on every bundle compile.

Cert **renewal** is a single in-place replace on the library row: the
same `id` keeps its `cert_pem` / `key_pem` / `not_after` updated, every
app pointing at it transparently rolls over on the next bundle pivot.

### Data model

New table `tls_certificates`:

| column | type | notes |
|---|---|---|
| `id` | uuid | binary_id, primary key |
| `label` | string | admin-supplied, e.g. "Sevensystem wildcard" |
| `pem` | bytea | encrypted via Cloak `Encrypted.Binary` |
| `key` | bytea | encrypted via Cloak `Encrypted.Binary` |
| `sans` | text[] | denormalised from cert at parse time, for fast match |
| `primary_san` | string | for display/sort |
| `issuer` | string | informational only (e.g. "GoGetSSL DV CA") |
| `not_before` | utc_datetime | from cert |
| `not_after` | utc_datetime | from cert; drives expiry alerts |
| `inserted_at` / `updated_at` | utc_datetime_usec | standard |

Applications schema changes:

- `cert_source` enum gains `:library` (alongside existing `:upload` /
  `:step_ca`).
- New column `tls_cert_id` (uuid, nullable FK to
  `tls_certificates.id`, `ON DELETE RESTRICT`).
- Old per-app columns `cert_pem` / `key_pem` stay for `:upload`
  callers — kept for backward compatibility; new deployments are
  expected to migrate to `:library`.

### Resolution algorithm (CertResolver)

Same algorithm runs both in Phoenix (admin UI preview + bundle
compile) and in the Go proxy (runtime SNI cert lookup). Given a
hostname and a cert list, the winner is the one whose SAN matches
with **highest specificity**:

```
exact host              → score = 1000 + len(san)
"*.parent.tld"          → score = len(parent.tld)
no match                → skip
```

Highest-score cert wins; ties broken by `not_after DESC` (newest
cert preferred — handles dual-provisioning during renewal).

When an app's `cert_source = :library` AND `tls_cert_id IS NULL`,
the bundle compile runs the resolver against the app's hostname and
materialises the FK into the bundle. The DB row stays NULL —
auto-match recomputes every compile, so a freshly added cert
"adopts" matching apps without manual reassignment.

### Replace-in-place semantics

The library page exposes a **Replace** action per row that overwrites
`pem` / `key` / `sans` / `not_after` on the existing record (same
`id`). Any app with `tls_cert_id` pointing at that row sees the new
cert on the next bundle pivot — zero per-app touches.

Validation guard before replace: if the NEW cert's SAN set fails to
cover one or more hostnames currently using this cert (either via
explicit FK or via auto-match), the UI surfaces the affected app
list and requires an explicit "Force replace" confirmation.

### Rationale

- **Pain killed**: a 10-app deployment under one wildcard cert was
  10 cert uploads + 10 renewals × 2-year cycle = 20 manual
  operations per cycle. Library + replace = 1 upload + 1 renewal,
  full stop.
- **No new secret material to manage**: same Cloak-encrypted at
  rest, same JSON bundle delivery to proxy, same SNI cert
  presentation logic.
- **Compatible with future ACME / step-ca**: the library is just
  another rows-of-pem store — when ADR-011's `:step_ca` path lands,
  step-ca-issued certs can also live in the library (label =
  app-id, replace = renewal) with no schema changes.

### Alternatives rejected

- **Org-level single default cert**: simpler, but doesn't cover
  multi-domain orgs (`*.sevensystem.vn` + `*.7-eleven.vn` is a real
  case for the first user). Library generalises.
- **Per-app upload with "copy from existing"**: still N database
  rows holding the same PEM, still N rows to update on renewal.
  Doesn't solve the renewal problem.
- **Auto-issuance only (force step-ca for everything)**: requires
  client-side root-CA install on every device for non-public
  hostnames — operationally heavier than uploading a real cert from
  a public CA.

### Consequences

- One more table to back up / encrypt-at-rest, but the secret-bearing
  surface (PEM + private key) is unchanged in kind — already encrypted
  via Cloak in the applications table.
- The auto-match path makes the cert chosen for a given hostname a
  function of the WHOLE library at bundle compile time. A new cert
  upload can change which cert is presented for an existing app — by
  design (so newer-issued, more-specific certs adopt their apps
  automatically). The library UI must surface "which apps will be
  affected" on upload + replace to make this visible.
- Bundle compile cost grows linearly with library size × app count
  (auto-match O(N×M)). At realistic scales (<100 certs, <1000 apps)
  the cost is negligible; if it ever matters, index the library by
  SAN suffix.
