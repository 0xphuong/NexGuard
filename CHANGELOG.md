# Changelog

All notable changes to NexGuard will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

---

## [3.0.4] - 2026-06-24

**Ops productivity polish.** Bulk actions on the devices list,
user-dropdown member picker on access groups, and a smarter
applications stats strip that no longer wastes a tile on the
unused `step-ca` source. No schema changes; no migration; no
operator action.

### Added

#### Bulk approve / revoke / delete on `/devices` ([UI-8](apps/fz_http/lib/fz_http_web/live/device_live/admin/index_live.ex))

Admins approving 20 pending devices used to click 20 times.
Checkbox column + sticky bulk toolbar replaces it:

- Per-row checkbox + select-all in the header (toggles all visible).
- Toolbar appears above the table when selection > 0, sticky to the
  navbar bottom so it stays in view during long-table scroll.
  Shows "N selected" + Approve / Revoke / Delete + Clear.
- Selected rows tint pale blue so admins can scan the affected set
  against the toolbar count.
- Delete goes through a confirmation modal listing the device names
  + user emails; Approve and Revoke execute immediately
  (reversible).

`FzHttp.Devices` gains `bulk_approve/3`, `bulk_revoke_approval/3`,
`bulk_delete/3`. Each iterates the id list, delegates to the
existing single-row function (preserving per-row audit log + PubSub
broadcast — no opaque "bulk" audit rows), and returns a
`%{ok, skip, error}` tally. `skip` covers no-op cases (already
approved / already pending) so partial sets read cleanly:

```
"Approved 12 device(s)."
"Approved 8 · skipped 2 (already in target state)."
"Approve: 8 ok · 2 skipped · 1 failed."
```

Shared `devices_table.html.heex` partial accepts opt-in
`bulk_enabled: true` + `selected: MapSet`. Other callers (user
show page, unprivileged list) leave it unset and render the
original table — no per-caller migration.

### Changed

#### Access-group member picker — dropdown instead of free-text email

`access-groups/<id>` Add-member field was a `<input type="email">`
that required typing the exact email. Typos returned a generic
"no user with email X" flash and there was no way to discover who
was even in the system.

Switch to a `<select>` populated with users NOT already in the
group, sorted by email, with role suffixed after a separator
("alice@x.com · admin"). Empty `@available_users` shows
context-aware copy: "No users in the system yet" with a link to
`/users`, or "Every existing user is already a member of this
group". Hint line under the form ("N users available") reads the
remaining headroom.

`add_member` handler now picks the branch by param shape — the
old `%{"email" => ...}` path stays as a fallback so any existing
external POST keeps working.

#### Applications stats strip — drop the dead `step-ca` tile (R5)

The four fixed tiles on `/applications` (Total / Enabled / Draft /
step-ca) made sense when the only cert sources were `:upload` and
`:step_ca`. ADR-015 added `:library` as the recommended default
and the step-ca tile reads 0 in almost every deployment.

Refresh to a conditional cert-source breakdown:

  * State tiles (Total / Enabled / Draft) always render.
  * Library / Upload / step-ca each render ONLY when their count
    is > 0. Mixed deployments show all three; freshly-migrated
    orgs see just Library; pre-migration legacy sees just Upload.
  * Each cert-source tile carries the matching MDI icon
    (`certificate-outline`, `cloud-upload-outline`,
    `shield-key-outline`) — matches the cert-source radio in the
    app form. Hover tooltip explains intent ("consider migrating
    to the cert library" on Upload).

### Fixed

#### Access-group member dropdown stale after add (Ecto preload no-op)

After successfully adding a member, the dropdown still showed that
user as available and a second Add click triggered the unique
constraint with a vague "Could not add" flash. Root cause:
`Repo.preload(group, [memberships: ...])` is a no-op when the
association is already populated on the struct (mount populates it,
then add_member re-uses the cached value). `force: true` makes
preload always re-query so the diff for `@available_users` sees the
just-inserted membership.

---

## [3.0.3] - 2026-06-24

**UI overhaul — calmer palette, ops-grade topbar, restructured nav,
audit log finally readable.** All themes deploy via SCSS rebuild;
no schema changes, no migration. Live on prod, untagged.

### Added

#### Audit log inline metadata viewer ([UI-3](docs/decisions.md))

The v3.0.2 hardening PR captured per-field diffs on
`application.update` events but the audit log page only showed
action/actor/target. Operators had to drop to `psql jsonb_pretty()`
to read the diff. UI-3 closes that loop:

- Chevron toggle per row reveals a detail panel below. Three render
  modes auto-detected from metadata shape:
  - `:diff` (before + after present) → side-by-side grid with
    unchanged rows dimmed and changed rows amber-highlighted
  - `:flat` → pretty-JSON dump
  - `:none` → "No metadata captured" hint
- Detail footer surfaces Log ID + Target ID + ISO timestamp as
  copyable codes for cross-referencing.
- Category filter dropdown gains Applications, Access Groups,
  L7 (signing), TLS Library, Org Settings.
- Mobile collapse: diff grid stacks to a single column ≤768px.

#### Topbar live service health ([UI-6 subset](apps/fz_http/lib/fz_http/health_monitor.ex))

New `FzHttp.HealthMonitor` GenServer polls Postgres, CoreDNS, and
the L7 proxy every 60s and broadcasts on `nexguard:health`. The
admin topnav renders three coloured pills via an embedded
`FzHttpWeb.TopbarHealthLive`; click any pill to force an immediate
manual probe (full sweep). State colours: green pulse (OK), amber
(degraded ≥500ms), red pulse (down), gray (unknown).

Probes:
- DB → `Ecto.Adapters.SQL.query` `SELECT 1`
- DNS → TCP connect `127.0.0.1:53` (CoreDNS binds TCP by default)
- Proxy → TCP connect `127.0.0.1:8443` (accept = listener alive)

All three are local syscalls / single round-trip — cost ~0 even
at the original 10s cadence; 60s leaves headroom for bigger
deployments.

#### Applications.Show URL-addressable tabs ([UI-5](apps/fz_http/lib/fz_http_web/live/applications_live/show.html.heex))

The single 500-line scroll on the app detail page split into four
URL-addressable tabs sharing one LiveView module:

```
/applications/:id            → Overview  (routing summary)
/applications/:id/policy     → Policy    (L7 rules editor)
/applications/:id/groups     → Groups    (allowed-groups picker)
/applications/:id/danger     → Danger    (enable/disable + delete)
/applications/:id/edit       → Edit modal (unchanged overlay)
```

Tab swap is a soft `<.link patch>` — no remount. Policy + Groups
tabs carry count badges (rule count, group count) in the nav so
admins know what's inside without clicking.

### Changed

#### Sidebar information architecture ([UI-2](apps/fz_http/lib/fz_http_web/live/sidebar_component.ex))

The L7 ZTNA stack used to span Configuration (Applications, Access
Groups) and Settings (TLS Certificates, L7 Enforcement). The daily
L7 workflow ("declare app → group users → provision cert → flip
enforcement") bounced between two sections.

Reshuffle into five clean sections matching admin mental model:

```
Main           → Dashboard
Configuration  → Users · Devices                      (identity inventory)
Access Control → Rules · Applications · Access Groups ·
                 TLS Certificates · L7 Enforcement     (policy, L3/L4 → L7)
Settings       → Client Defaults · Network · Security ·
                 Customization · Account · Audit Log
Diagnostics    → WAN Connectivity
```

L7 Enforcement icon swapped to `mdi-shield-key-outline` (was generic
`mdi-power`); Access Groups uses `mdi-account-multiple-check-outline`
(distinct from Users' `mdi-account-group-outline`).

#### Brand palette ([Issue 1](apps/fz_http/assets/local_modules/admin-one-bulma-dashboard/src/scss/_theme-nexguard.scss))

The previous orange (#FF7300) + saturated-purple (#5E00D6) accent
read more like consumer SaaS than security ops. Swap to a
Tailwind-aligned cool palette:

| | Was | Now |
|---|---|---|
| primary  | #FF7300 (orange) | #2563eb (blue-600) |
| accent   | #5E00D6 (purple) | #0891b2 (cyan-600)  |
| interface base | #1B140E (warm brown) | #0f172a (slate-900) |
| success  | #80B900 (yellow-green) | #16a34a (emerald-600) |
| warning  | #FFB900 (orange-yellow) | #d97706 (amber-600) |
| danger   | #990C00 (oxblood) | #dc2626 (red-600) |

Single file edit (`_theme-nexguard.scss`); every downstream `$primary-NNN`
/ `$accent-NNN` / `$interface-NNN` reference picks up the new hex on
rebuild — no template changes.

---

## [3.0.2] - 2026-06-24

**ADR-015 — shared TLS certificate library.** Plus Applications
hardening landed in the same release window (close `enable` bypass
in update path + capture full per-field diff in audit metadata).
Live on prod, untagged.

### Added

#### TLS Certificate Library ([ADR-015](docs/decisions.md))

Admins upload each wildcard / multi-SAN cert ONCE at
`/settings/certificates`; L7 apps either pin via `tls_cert_id` (explicit)
or auto-match by hostname → SAN specificity at bundle compile.
Renewal = one-click in-place Replace; every app pointing at the row
rolls over on the next bundle pivot. Zero per-app touches.

Migration `20260624000001_create_l7_tls_certificates` introduces the
table; `20260624000002_add_tls_cert_ref_to_applications` adds the FK
+ `tls_auto_match` boolean.

New modules:
- `FzHttp.L7.TlsCertificate` — schema (pem + key Cloak-encrypted)
- `FzHttp.L7.CertParser` — PEM → SAN/expiry/issuer, enforces RSA
  ≥ 2048, ECDSA P-256+, cert ↔ key match, ≥24h remaining validity
- `FzHttp.L7.CertResolver` — pure SAN-specificity matcher; exact >
  wildcard, tie-break by `not_after DESC`
- `FzHttp.L7.TlsCertificates` — context with `affected_apps/1`
  preview for replace/delete confirmation
- `FzHttp.L7.TlsCertExpiryScanner` — daily sweep, audit-log alerts
  at 30d / 7d / expired thresholds (23h dedupe)
- `FzHttpWeb.SettingLive.Certificates` — list / upload / replace /
  delete LiveView at `/settings/certificates`

Application `cert_source` enum gains `:library` alongside `:upload`
and `:step_ca`. App form gets a recommended-default radio for
library + live "Will use: <cert label>" preview as admin types
hostname.

### Changed

#### Applications hardening

- **Closed enable-bypass via update path**. `update_changeset` used
  `@permitted_create -- [:virtual_ip]` which let `:enabled` through
  the cast — a posted `update_application(app, %{"enabled" => true})`
  would flip an under-configured app live without
  `validate_required_for_enable/1`. Explicit `@permitted_update`
  list replaces the brittle subtraction; both `:enabled` and
  `:virtual_ip` are excluded.
- **`application.update` audit metadata** captures the full per-field
  diff (name, hostname, backend, cert_source, tls_cert_id,
  tls_auto_match, tls_mode, **l7_rules verbatim**) — was previously
  just `{name, backend, tls_mode}`, leaving the actual ZTNA policy
  surface invisible to compliance review.

#### CoreDNS

`fallthrough .` (with the root zone explicit) replaces bare
`fallthrough` — sister names under declared internal zones
(e.g. `loki-grafana.sevensystem.vn` when only `hq.sevensystem.vn`
is L7-onboarded) now resolve via the forward plugin instead of
NXDOMAIN-authoritative from the hosts plugin.

Optional `COREDNS_FORWARD_TO_FALLBACK` env knob — second resolver
used by `policy sequential` when the primary fails health check.
Default echoes the primary, so leaving it unset is "no failover"
(safe).

### Fixed

- **`CertParser` microsecond precision** — X.509 validity timestamps
  are second-precision (`YYMMDDhhmmssZ`). `DateTime.from_iso8601`
  returns `{_, 0}` microsecond precision; Ecto's `:utc_datetime_usec`
  dumper rejects with `expects microsecond precision`. Force
  `{0, 6}` at the parser boundary.
- **Cert library upload modal** — stateful LiveComponent requires a
  single static HTML tag at the root; `<.form>` is a function
  component which the diff engine rejected. Wrap in `<div>`.
- **Cert library modal submit silently failing** — `live_modal`
  renders its own submit button in the modal footer with HTML
  `form=<id>` attribute association; the cert page didn't pass
  `form:` + `button_text:` opts so the button had no form
  association → clicking did nothing.

### Test coverage

~30 test cases across:
- `cert_parser_test.exs` — SAN extraction, key-mismatch reject,
  weak RSA reject, expired reject, microsecond precision
- `cert_resolver_test.exs` — specificity rules, tie-break by
  not_after, case-insensitive match
- `tls_certificates_test.exs` — CRUD, replace-keeps-id,
  delete-blocked-when-pinned, audit log entries
- `certificates_live_test.exs` — mount, upload flow, delete
  confirm modal
- `tls_cert_expiry_scanner_test.exs` — severity classification,
  audit dedupe

Audit log whitelist gains `tls_cert.create`, `tls_cert.replace`,
`tls_cert.delete`, `tls_cert.expiry_warning`.

---

## [3.0.1] - 2026-06-24

**Security hardening from the L7-D security review backlog plus
DNS / runbook fixes hit during prod smoke testing.** Live on prod,
untagged. Breaking-ish: backends behind the proxy MUST start
validating `iss` and `aud` (see [docs/migrations/v3.0.1.md]).

### Changed

#### JWT claims (BREAKING for backends)

The L7 proxy now stamps four extra claims on every
`X-NexGuard-Identity-Jwt`:

```json
{ "iss": "nexguard-proxy",
  "aud": "<the L7 app's UUID>",
  "jti": "<16-hex random per call>",
  "nbf": <same as iat> }
```

Without `aud`, a token minted for app A is structurally identical
to one for app B — same user, same groups, same signature key. A
compromised app A could replay tokens at app B. Backends MUST now
assert `iss == "nexguard-proxy"` AND `aud == <their app uuid>`.

Roll-out order matters: ship backend `iss`/`aud` checks in lenient
mode FIRST (allow missing claims during bake window), THEN deploy
proxy v3.0.1, THEN flip backends to strict. See
[`docs/migrations/v3.0.1.md`](docs/migrations/v3.0.1.md) for Go +
Elixir validation examples.

#### Proxy hardening

- **X-Forwarded-* strip before forward** — proxy no longer trusts
  client-sent XFF headers (spoofable). Re-adds a canonical
  `X-Forwarded-For` with the real WG-side client IP.
- **Path normalization** — `..`, double-slash, percent-encoded
  traversal rejected in policy eval before rule match. Closes a
  path-traversal-via-prefix-rule class of bug.
- **JWT signature redacted in logs** — log lines show `aud=...`,
  never the signature bytes.
- **PEM zeroed in memory after parse** — proxy no longer holds the
  signing key as a Go string (immutable + GC-tracked) once the
  signer is built; raw bytes wiped.
- **`WriteHeader` guard** — defensive `sync.Once`-like guard around
  response writes; prevents a panic from a buggy double-write path.

#### CoreDNS cache-heavy + multi-resolver

`coredns/Corefile` tuned to absorb the per-client query storm
(Apple/iOS chatter, browser prefetch, HTTPS-RR):

```
cache {
  success 16384 3600 60
  denial 4096 300 30
  serve_stale 1h immediate
  prefetch 10 1m 10%
}
template ANY ANY local lan home internal corp { rcode NXDOMAIN }
forward . {$COREDNS_FORWARD_TO} {
  max_concurrent 100
  health_check 5s
  expire 30s
  policy sequential
}
```

Net effect: a single upstream sees ~85-90% fewer queries than raw
client load; `serve_stale 1h` keeps clients fast through upstream
outages.

#### Audit whitelist (12 missing actions)

`AuditLog.@valid_actions` extended with 12 L7 / app / group / scope
actions that the codebase emits but were silently dropped before:
`l7.signing_key.bootstrap`, `l7.signing_key.rotate`,
`access_group.{create,update,delete,add_member,remove_member}`,
`application.{create,update,delete,enabled.change,allow_group,revoke_group}`,
`org_settings.l7_enabled.change`, `user.access_scope.change`. Plus
a regression test that pins the whitelist catalogue.

### Fixed

- **CoreDNS sister-name NXDOMAIN** — bare `fallthrough` was scoped
  wrong; sister names under a declared internal zone
  (e.g. `loki-grafana.sevensystem.vn` when `hq.sevensystem.vn` is
  in the L7 hosts file) returned NXDOMAIN-authoritative from the
  hosts plugin instead of falling through to forward. Explicit
  `fallthrough .` with the root zone fixes it.

- **Auto-append L7 VIP /16 to client `AllowedIPs`** — pre-v3.0.0
  client `.conf` files didn't include `10.99.0.0/16` so packets
  for L7 VIPs went out the local interface instead of through the
  WG tunnel. New `FzHttp.L7.vip_cidr/0` + WG config view appends
  it automatically; existing clients need to re-download their
  `.conf` and reconnect.

- **L7 deploy gotchas** captured in `docs/migrations/v3.0.0.md`:
  rebuild orphans namespace dependents (need force-recreate),
  `.env` line discipline (`tee -a` without trailing newline
  concatenates onto previous line), `nft tproxy` family attr
  ordering (`tproxy ip to ...` not `tproxy to ...`).

---

## [3.0.0] - 2026-06-21

**L7-D — L7 transparent proxy daemon GA**. The custom Go binary
under `proxy/` is now production-ready: terminates per-app TLS,
looks up VPN-IP identity from the server, evaluates inline policy
rules, mints + injects a signed identity JWT, and reverse-proxies
to the declared backend. Plus the mTLS-protected internal control
plane Caddy listener at `:13443` that the proxy uses to fetch the
bundle.

**Breaking change**: `/internal/*` paths are now HARD-404'd at the
public :443 listener. Anyone still hitting those URLs from the
public DNS (only ever us, for smoke testing — there is no real
consumer) will see a 404. Use the new mTLS endpoint at `:13443`
with the issued client cert instead.

### Added

#### L7 proxy daemon (`proxy/`)

A 5-7 KLOC Go binary, single-binary deploy via the new
`docker-compose.proxy.yml` opt-in overlay. ~20 MB distroless static
image.

- **Bundle client** with `If-None-Match` + `?since=N` long-poll and
  atomic-swap pointer for race-free hot-path reads.
- **Identity client** with a 30 s TTL cache, ETag-aware refresh,
  `Invalidate`/`InvalidateAll` for PubSub-driven invalidation in a
  follow-up release.
- **RS256 JWT signer** built on stdlib `crypto/rsa` (no third-party
  JWT lib). PKCS#1 + PKCS#8 PEM accept paths. Minimum 2048-bit
  modulus enforced at parse time.
- **SNI cert store** keyed by hostname from the bundle; bundle
  pivots atomic-swap the store without dropping in-flight TLS
  handshakes.
- **`IP_TRANSPARENT` TCP listener** with TLS 1.3 wrapping
  (`MinVersion: TLS13`). Build-tag split so non-Linux dev hosts
  compile but errors at listen time. TPROXY model — `conn.LocalAddr()`
  recovers the original-DST VIP, no `SO_ORIGINAL_DST` getsockopt
  needed.
- **Policy evaluator**: break-glass on `access_scope=all`, then
  app-wide group gate, then first-match-wins rule eval over
  `method` / `path_prefix` / `require_groups` /
  `require_mfa_age_seconds`. Default deny on no match.
- **Reverse proxy** via `httputil.NewSingleHostReverseProxy` with
  custom transport pinning TLS 1.2+ on the backend hop. `Host` set
  to the backend's host (no vhost confusion). Response headers
  scrubbed of any `X-NexGuard-*` the backend might emit. Backend
  scheme allow-listed to `http`/`https` (SSRF defense).
- **Header massage** in dependency order: strip client-supplied
  `X-NexGuard-*`, apply per-app `strip_headers`, apply per-app
  `inject_headers` BUT refuse to overwrite the reserved
  `X-NexGuard-*` namespace, then inject identity headers + JWT as
  the last writer. An admin's bundle config cannot impersonate
  identity headers.
- **Structured per-request access log** (`slog` JSON): ts, decision
  (allow/deny/error), reason, app_id, user_id, vip, status,
  bytes_out, latency, method, path, ua, client. JWT and PEMs
  never logged.
- **Prometheus metrics** on a second port (default
  `127.0.0.1:9090`): `nexguard_proxy_requests_total{decision,
  status_family}`, `nexguard_proxy_request_duration_seconds{decision}`,
  `nexguard_proxy_bundle_{version,age_seconds}`,
  `nexguard_proxy_identity_cache_size`. Plus `/healthz` (always 200)
  and `/readyz` (200 when bundle loaded; 503 during boot or after
  signal-triggered drain).
- **`--health-probe` subcommand** for Docker `HEALTHCHECK` from
  distroless (no curl/wget).
- **Graceful shutdown** on SIGTERM/SIGINT: flips `/readyz` to 503
  so the LB drains; finishes in-flight requests; exits.

#### mTLS internal control plane

- **`scripts/l7-rotate-proxy-cert.sh`** — openssl-driven cert
  rotation. Generates a 4096-bit RSA internal CA (10-year
  validity) + 2048-bit RSA leaves for the Caddy server cert + the
  proxy client cert (1-year validity each). Idempotent: re-running
  rotates the leaves; `--reset-ca` rotates the CA. Old certs
  archived under `<NEXGUARD_CERTS_DIR>/archive/<ts>/`.
- **Caddy `:13443` mTLS listener** in `docker-compose.prod.yml`,
  loaded only when the cert files exist. `require_and_verify` mode
  against `internal-ca.pem`. Reverse-proxies to Phoenix on the
  bridge IP — exact same backend as :443.
- **`/internal/*` hard-404 on the public :443 listener.** Anyone
  reaching the portal hostname can no longer poke control-plane
  endpoints regardless of mTLS state.
- **Proxy client cert wiring**: `NEXGUARD_PROXY_CLIENT_CERT`,
  `NEXGUARD_PROXY_CLIENT_KEY`, `NEXGUARD_PROXY_CA_BUNDLE`
  environment variables. `bundle.Client` and `identity.Client`
  share a configured `http.Client`. Plain `http://` is rejected
  unless the host is loopback.

#### Server-side bundle additions

- **`signing_key.{kid,algorithm,private_pem}`** in every bundle
  response — the proxy needs the private half to sign JWTs.
  Threat model unchanged (the bundle already carries every app's
  TLS cert and key; the signing key joins them under the same
  protection).
- **`apps[].key_pem`** alongside the existing `cert_pem` so the
  proxy can terminate TLS for each declared SNI hostname.

#### Tests

- Unit coverage in each `proxy/internal/<pkg>/` plus a composed
  integration test in `proxy/internal/integration/` that drives
  the full pipeline against mock NexGuard + mock backend. JWT
  signature end-to-end verifies with `crypto/rsa.VerifyPKCS1v15`
  against the fixture's matching public key.
- Perf test (gated by `NEXGUARD_PERF=1`): asserts ≥ 1000 rps and
  p99 ≤ 50 ms. Measured 1143 rps / p99 21 ms on macOS arm64.

### Security review

Independent review of the proxy code surfaced and fixed:

- **C1**: per-app `inject_headers` / `strip_headers` can no longer
  overwrite reserved `X-NexGuard-*` identity headers — bundle ingest
  filters the reserved prefix and identity injection runs last.
- **C2**: JWT signer rejects RSA keys under 2048 bits.
- **H1**: bundle/identity HTTP client rejects plain `http://`
  unless the target is loopback; mTLS is the supported path for
  cross-host deployments.
- **H2**: reverse-proxy `Transport` pins `MinVersion: TLS12`,
  forces HTTP/2 attempt, and the `ModifyResponse` hook strips any
  upstream-emitted `X-NexGuard-*` so backends can't pollute the
  client-facing response with proxy-looking headers.
- **H3**: backend scheme allow-listed to `http`/`https` at proxy
  build time — `file://`, `gopher://`, etc. are refused.
- **H4**: `pollBundle` now calls `identity.Client.InvalidateAll`
  on every bundle pivot so a user removed from a group / disabled
  doesn't survive in the 30 s identity cache.
- Identity client refuses to fall back to a raw `RemoteAddr` when
  `net.SplitHostPort` fails — bad addr → 400 + log, not silent
  cache key divergence.

Medium-severity issues (M1: Host header overwrite — actually
already handled; M2: path-prefix normalization; M3: missing
`aud`/`iss`/`jti` claims; M5: query-string redaction in access
log) are documented and tracked for v3.0.1. Low-severity items
(L1-L3) are accepted as documented behavior.

### Operational caveats

- The proxy is dormant until **both** `org_settings.l7_enabled =
  true` AND an admin declares + enables at least one application.
  Default fresh-install state is safe.
- The mTLS listener at :13443 only loads when the cert files
  exist. A fresh install that hasn't run `l7-rotate-proxy-cert.sh`
  boots with the public :443 portal only — no errors, no exposure.
- Cert lifecycle: proxy cert 1 year, CA 10 years. Re-run the
  rotation script + restart Caddy + restart proxy before the
  proxy cert expires.

### Migration runbook

[`docs/migrations/v3.0.0.md`](docs/migrations/v3.0.0.md) walks
through every step: cert provisioning, Caddy verification, proxy
overlay activation, kill-switch operation, cert rotation, and
three independent rollback paths.

---

## [2.4.0] - 2026-06-21

L7 ZTNA Phase 3 — **network plumbing for the upcoming L7 proxy
daemon**. nftables TPROXY chain, fwmark + loopback routing, and an
opt-in CoreDNS sidecar with a Phoenix-side hosts-file generator. As
with v2.3.0, **no end-user behaviour change**: the L7 proxy daemon
(L7-D) hasn't shipped yet, so flipping `org_settings.l7_enabled = true`
would redirect declared-VIP traffic into a closed port. **Keep the
toggle off until L7-D ships.**

### Added

#### fz_wall TPROXY chain (C-1 / C-2 / C-3)

- **`FzWall.CLI.Helpers.Tproxy`** module shells out to `nft` + `ip`:
  - `install_l7_chain/0` — adds an `l7_prerouting` chain hooked at
    `prerouting / priority mangle`. The single rule matches packets
    arriving on the WireGuard interface destined for any IP in
    `10.99.0.0/16` on TCP 80 or 443, marks them with `0x1`, and
    `tproxy to 127.0.0.1:8443`. Idempotent.
  - `remove_l7_chain/0` — flush + delete the chain. Safe to call
    when it doesn't exist.
  - `install_fwmark_route/0` — adds the loopback routing table
    (`ip route add local 0.0.0.0/0 dev lo table 100`) + the rule
    (`ip rule add fwmark 0x1 lookup 100`) that makes the TPROXY
    socket actually receive marked packets. Zero-cost when no marks
    flow, so installed at every fz_wall boot regardless of toggle.
- **`FzWall.Server`** now subscribes to `nexguard:l7:settings`. On
  `{:l7_enabled_changed, true}` it calls `install_l7_chain/0`; on
  `false` it calls `remove_l7_chain/0`. Boot time also queries
  `FzHttp.OrgSettings.l7_enabled?/0` and reinstalls the chain
  immediately if the toggle is already on (handles container
  restart while L7 is active).

#### CoreDNS hosts generator (C-5 / C-6 / C-7)

- **`FzHttp.L7.CoreDnsHosts`** GenServer writes
  `/etc/nexguard/internal-hosts` from
  `Applications.list_enabled_for_bundle/0`. Atomic write (tmp file
  + rename) so CoreDNS's `reload 1s` poll never sees a partial
  state. Subscribes to `nexguard:l7:apps`; regenerates on every
  Applications mutation. Singleton-with-override convention so
  tests pass a unique `:path`.
- Added to the `:full` supervision tree after `BundleBuilder`.

#### CoreDNS opt-in compose overlay (C-4)

- **`docker-compose.coredns.yml`** — opt-in overlay activating a
  CoreDNS 1.11 sidecar. Adds a shared host bind mount
  (`${FZ_INSTALL_DIR:-.}/coredns-hosts → /etc/nexguard`) so the
  Phoenix-side generator and the CoreDNS reader see the same file.
- **`coredns/Corefile`** — hosts plugin with `reload 1s` for the
  declared VIPs, `forward . 1.1.1.1 8.8.8.8` fallthrough for
  everything else, 30 s cache.

#### Runbook + docs (C-10 / C-11)

- **`docs/migrations/v2.4.0.md`** — pre-flight (kernel ≥ 5.6.9 +
  port 53 collision with systemd-resolved), apply (with vs without
  the overlay), verification steps, kill-switch behavior, and a
  full rollback recipe.
- **`NEXGUARD_LOGIC.md`** §17 — runbook details linked from this
  changelog cover the chain + Corefile shape.

### Operational caveats

- **Dormant by default.** `l7_enabled = false` ⇒ TPROXY chain is
  not installed; the `Tproxy` helper compiles into the binary but
  never shells out unless someone flips the toggle.
- **No L7 proxy yet.** Flipping `l7_enabled = true` before L7-D
  ships will break traffic to declared VIP apps. Real-user impact
  is bounded to traffic that resolves a declared `hostname` via
  the CoreDNS overlay (otherwise the VIPs are unreachable anyway).
- **IPv4 only.** Both the TPROXY rule and the hosts-file output
  are IPv4-only. IPv6 support lands with L7-D's dual-stack proxy.
- **Port 53 collision.** If running the CoreDNS overlay,
  systemd-resolved must be released from :53 first — runbook walks
  the operator through the safe path.

### Tests

- `test/fz_http/l7/coredns_hosts_test.exs` — atomic write, header,
  sorted `<vip> <hostname>` rendering, parent-dir creation, and
  `:apps_changed` end-to-end regenerate.
- nftables shell-out paths in `FzWall.CLI.Helpers.Tproxy` go
  through the existing Live/Sandbox adapter; the Sandbox stubs are
  no-ops so the umbrella test suite still runs cleanly on macOS.

---

## [2.3.0] - 2026-06-21

L7 ZTNA Phase 2 — the **server-side data plane** the upcoming L7
proxy daemon (ships in L7-D) will read from. This release adds the
JWT signing infrastructure, identity lookup API, signed policy
bundle, and PubSub invalidation channels. **Still no runtime
behaviour change for end users** — the L7 subsystem stays dormant
until the proxy daemon lands. Endpoints are reachable but no
consumer is calling them yet.

mTLS gating of `/internal/*` (Phase 6 of L7-B) is **deferred** to
the L7-D release so cert provisioning + the proxy daemon ship in
the same drop — see `task.md`.

### Added

#### JWT signing infrastructure (Phase 1)

- **`l7_signing_keys` table** (migration `20260621000001`) — UUID PK,
  unique `kid`, `algorithm` (default `RS256`), Cloak-encrypted
  `private_pem`, plain `public_pem`, `active boolean`, `rotated_at`.
  Partial unique index on `active = true` enforces single-active-key
  invariant at the DB level.
- **`FzHttp.L7.JwtSigner`** GenServer — cold-boot bootstrap (generates
  an RS256 keypair + audits `l7.signing_key.bootstrap` on first init),
  `sign/2`, `verify/1`, `active_kid/0`, `jwks/0`, `rotate/3`. Grace
  window keeps the last 3 rotated keys in memory so in-flight tokens
  still verify across a rotation. Follows the singleton-with-name
  override convention shared with `FzHttp.Notifications` so tests can
  spawn isolated instances under `start_supervised!/1`.
- **`GET /.well-known/jwks.json`** — public RFC 8615 + RFC 7517
  endpoint serving active + grace keys. `Cache-Control: public,
  max-age=300` matches the grace window so a stale proxy cache still
  verifies in-flight tokens until refresh.
- Whitelist `l7.signing_key.{bootstrap,rotate}` actions in
  `FzHttp.AuditLogs.AuditLog.changeset/2` — otherwise the changeset
  silently rejected the rows and key-lifecycle events never landed
  in the audit log.

#### Identity API (Phase 2)

- **`FzHttp.L7.Identity.lookup_by_vpn_ip/1`** — single preloaded
  query joining `devices` ↔ `users` ↔ `access_groups` matched on
  `devices.ipv4` OR `devices.ipv6`. Returns `{:ok, identity,
  cache_meta}` or `:not_found`. Fail-closed on unparseable IP,
  multi-match (data corruption), and disabled users.
- **`mfa_age_seconds`** = elapsed seconds since `last_signed_in_at`
  when the user has at least one configured MFA method; `nil`
  otherwise so the proxy doesn't mistake a password-only sign-in
  timestamp for MFA freshness.
- **`GET /internal/sessions/by_vpn_ip/:ip`** — `FzHttpWeb.Internal.IdentityController`.
  `Cache-Control: private, max-age=30` + weak ETag
  `W/"md5(user_id:user.updated_at)"`. `If-None-Match` returns 304.
  404 + `{"error":"unknown_vpn_ip"}` on any fail-closed path.

#### Bundle compile + endpoint (Phases 3 + 4)

- **`FzHttp.L7.BundleBuilder`** GenServer — subscribes to
  `nexguard:l7:{apps,settings,groups}`; any event schedules a 300 ms
  debounced recompile so a burst of admin clicks coalesces to one.
  On compile, builds the bundle map (`schema_version`,
  `bundle_version`, `compiled_at`, `org_settings`, `jwks`, `apps`,
  `groups`), encodes to JSON, signs, writes to a public ETS table
  (`{:current, entry}` + `{{:history, n}, entry}` LKG ring of last 3
  versions), and broadcasts `{:bundle_updated, version}` on
  `nexguard:l7:bundle`.
- **Bundle signature**: JWT with `bundle_sha256` claim signed by
  `JwtSigner.sign/2` and carried in the
  `X-NexGuard-Bundle-Signature` response header. Pragmatic
  alternative to a strict RFC 7797 detached JWS — proxy verifies
  the JWT against the public JWKS, computes its own SHA-256 of the
  body, and compares.
- **`GET /internal/bundle.json`** — `FzHttpWeb.Internal.BundleController`.
  Reads `BundleBuilder.current/0` directly from ETS — no GenServer
  hop on the hot path. `ETag: "v<N>"`, `If-None-Match` → 304.
  `?since=N` long-poll: 304 when `current_version <= N`. 503 +
  `bundle_not_compiled` when the table is empty.

#### PubSub wiring + identity invalidation (Phase 5)

- **`FzHttp.AccessGroups.{create,update,delete}_group` + `{add,remove}_member`**
  now broadcast `:groups_changed` on `nexguard:l7:groups`
  (previously the BundleBuilder subscribed but no one published).
  Public `subscribe_groups/0` helper.
- **`FzHttp.L7.broadcast_identity_change/1`** — new helper that
  fans out one `{:identity_updated, vpn_ip}` event per active VPN
  IP attached to a user's devices, so the proxy invalidates its
  30 s identity cache only for the keys that actually changed.
  Called from `Users.update_user/4` (only when role changes),
  `Users.set_access_scope/4` (only on real change), and
  `AccessGroups.{add,remove}_member/4`.

### Fixed

- **`FzHttpWeb.ErrorView.template_not_found/2`** no longer returns
  the raw exception struct (`%Phoenix.Router.NoRouteError{}`) when
  the router 404s on a path with no template. Crawlers hitting
  `/sitemap.xml`, `/robots.txt`, etc. were causing a secondary
  `Protocol.UndefinedError` because `Phoenix.HTML.Safe` has no impl
  for arbitrary structs. The view now always emits a plain string
  for HTML and a JSON-safe map for JSON.

### Migrations

One additive migration: `20260621000001_create_l7_signing_keys`.
Safe to apply on a running production. See
[`docs/migrations/v2.3.0.md`](docs/migrations/v2.3.0.md) for the
runbook. No manual bootstrap step — `JwtSigner` generates the
first key on its first init.

### Notes

- `/internal/*` endpoints are **reachable from any client that can
  reach the public DNS for the portal**. Until L7-D ships with mTLS
  enforcement, this is a small but real information-leak surface
  for an attacker who can guess a valid VPN IP. The risk is
  bounded by VPN IP allocation (100.64.0.0/10) and by the fact
  that the data plane (proxy + step-ca) is not deployed yet.
- `FzHttp.L7.JwtSigner` private-pem column is Cloak-encrypted — the
  same vault config that gates `applications.key_pem` since v2.2.0.
  If the vault is misconfigured, the GenServer crashes on first
  bootstrap (visible in container logs).

---

## [2.2.0] - 2026-06-21

L7 ZTNA Phase 1 — admin data + UI surface for the upcoming layer-7
transparent proxy (see `docs/decisions.md` ADR-007 → ADR-014). The
proxy itself (CoreDNS + Go binary + smallstep) ships in L7-B → L7-F
across later releases; this release lands the database, contexts, and
admin tooling that those data-plane pieces will read from. **No
runtime behaviour change for end users on 2.2.0** — the L7 subsystem
ships dormant until the org-level toggle is flipped AND the proxy
binaries are deployed (planned for v3.0.0).

### Added

#### Data model (Phase 1 — DB schema)

Six additive migrations (`20260620000001` → `20260620000006`), safe
to apply on a running production. See
[`docs/migrations/v2.2.0.md`](docs/migrations/v2.2.0.md) for the
runbook.

- **`access_groups`** — manual / IdP-synced groups that gate L7-app
  reachability (ADR-014).
- **`user_group_memberships`** — composite-PK M:N join with provenance
  (`source: manual | idp_sync`) so a SCIM reconciliation job can leave
  manual memberships alone.
- **`applications`** — NEW table for L7-managed apps. Columns:
  `hostname` (unique, RFC 1035 validated), `virtual_ip` (`inet`,
  unique inside `10.99.0.0/16`), `backend`, `cert_source` enum
  (`upload | step_ca`), `cert_pem`, `key_pem` (Cloak-encrypted at
  rest), `tls_mode` (`terminate | passthrough`, passthrough deferred
  to v2), `l7_rules` (`jsonb`), `enabled`.
- **`application_allowed_groups`** — composite-PK M:N between apps
  and groups (ADR-014 group intersection check).
- **`users.access_scope`** — break-glass bypass marker
  (`limited | all`, default `limited` per ADR-008).
- **`org_settings`** — singleton row (CHECK constraint enforces
  `id = 1`), seeded with `l7_enabled = false`. Kill switch per
  ADR-014.

#### Elixir context layer (Phase 2)

- `FzHttp.AccessGroups` — CRUD + member add/remove + identity-API
  + bundle readers (`list_groups_for_user/1`,
  `list_groups_with_members/0`).
- `FzHttp.Applications` — CRUD with **in-transaction VIP allocation**
  so concurrent admin requests can't collide on the same VIP; M:N
  allowed-groups; per-mutation PubSub on `nexguard:l7:apps`.
- `FzHttp.OrgSettings` — singleton get/toggle + PubSub on
  `nexguard:l7:settings`. No-op detection skips audit + broadcast on
  identical writes.
- `FzHttp.L7.VipAllocator` — first-free scan over
  `10.99.0.1` → `10.99.255.254` with a Postgres advisory lock so two
  concurrent `create_application` requests serialise.
- New authorizers: `FzHttp.AccessGroups.Authorizer`,
  `FzHttp.Applications.Authorizer`, `FzHttp.OrgSettings.Authorizer` —
  admin-only; unprivileged subjects see nothing. All three registered
  in `FzHttp.Auth.Roles.list_authorizers/0`.

#### Admin UI (Phase 3)

- **`/access-groups`** — list (with stats strip), create-via-modal,
  detail page with inline edit, member roster, danger-zone delete.
- **`/users/:id`** — two new cards on the existing user detail page:
  - **Group Memberships** — add-to-group dropdown of unlinked groups,
    table of current memberships with link back to each group's
    detail page, styled-modal remove.
  - **L7 Access Scope** — `limited` / `all` badge in the header,
    single-button toggle with a styled break-glass confirmation modal
    showing before → after badge transition.
- **`/applications`** — list with stats strip + delete via styled
  modal.
- **`/applications/new`** + **`/applications/:id`** +
  **`/applications/:id/edit`** — full form: name, description,
  hostname (RFC 1035 live-validated), backend URL,
  card-style cert source picker, conditional cert + key PEM textareas
  with inline X.509 preview (Subject, SANs, expiry) when the PEM
  parses; Show page with hero, Routing card, L7 Rules row editor
  (action / methods as pill checkboxes / path_prefix / require_groups
  / require_mfa_age + up/down reorder + implicit-deny indicator
  pinned at the bottom), Allowed Groups picker, danger zone with
  Enable/Disable + Delete.
- **`/settings/l7`** — org kill switch. Status banner listing
  enabled-apps count + VIP subnet + TPROXY port when active.
  Confirmation modals with concrete bullet lists for both directions.
- All destructive actions (group delete, member remove, app delete,
  access-scope flip, L7 toggle) use the canonical
  `modal-card` + `ng-modal-*` Bulma pattern instead of browser
  `confirm()` dialogs.

#### Tests

- `test/fz_http/access_groups_test.exs`,
  `test/fz_http/applications_test.exs`,
  `test/fz_http/l7/vip_allocator_test.exs`,
  `test/fz_http/org_settings_test.exs` — context-layer coverage
  (~590 LOC).
- `test/fz_http_web/live/{access_groups_live,applications_live,setting_live,user_live}/...` —
  4 LiveView test files covering happy-path + critical validation +
  styled-modal flows.

### Dependencies

- `{:x509, "~> 0.8"}` — parses uploaded cert PEMs so the changeset can
  refuse a cert whose SAN/CN doesn't cover the declared hostname.

### Notes

- **L7 enforcement is dormant after this release.** The
  `org_settings.l7_enabled` toggle defaults to `false`; flipping it
  on doesn't break anything because the data plane (CoreDNS + L7
  proxy + step-ca) is not deployed yet — those land in L7-B → L7-F.
- The `key_pem` column stores Cloak-encrypted ciphertext; the
  `FzHttp.Vault` config must be set in your prod env if you intend to
  use the `upload` cert source. The `step_ca` path doesn't touch
  the column.

---

## [2.1.1] - 2026-06-19

Admin-facing notifications for the device approval workflow. The
in-portal notification system existed (badge + Notifications page) but
was only ever fired for VPN config-sync errors. Now it surfaces the
event admins actually need to act on: a self-enrolled device sitting
in `pending` state waiting for them.

### Added

- **Pending-device notification** fires from
  `Devices.find_or_create_for_user/3` when a new native enrollment
  lands in `pending`. The Notifications GenServer broadcasts via
  PubSub, so the navbar badge + Notifications page light up in real
  time — no refresh needed. Payload carries `device_id` so subsequent
  state changes can target it precisely
  (`apps/fz_http/lib/fz_http/devices.ex`,
  `apps/fz_http/lib/fz_http/notifications.ex`).
- **`Notifications.clear_for_device/1`** API + GenServer handler.
  Clears every notification whose payload has `device_id == id`.
- **`:warning` and `:info` icon variants** on the Notifications page
  (`apps/fz_http/lib/fz_http_web/live/notifications_live/index_live.ex`).
  CSS classes `ng-notif-icon--warning` / `--info` were already in
  `main.scss` from prior design work, so no styling change needed.

### Changed

- **`Devices.approve_device/3`** now calls
  `Notifications.clear_for_device/1` after the status transitions to
  approved — the pending banner disappears from the admin's list
  without a manual dismiss.
- **`Devices.revoke_approval/3`** fires a fresh pending-approval
  notification when an admin demotes an already-approved device. The
  text differs slightly ("was revoked and is back to pending
  approval") so the admin sees this is a re-arm, not a duplicate of
  the original enrollment.
- **`Devices.delete_device/3`** clears any pending notification for
  the deleted device — a stale "pending approval" banner for a row
  that no longer exists would be a UI bug.

### Notes

- Notifications are still in-memory only (GenServer state). They are
  wiped on app restart — consistent with the existing behavior of the
  notification subsystem. Persistence is a separate concern.
- Future polish (deferred): email / webhook out when a pending device
  appears, for teams where admins don't sit in the portal all day.

---

## [2.1.0] - 2026-06-14

Admin-facing controls for native devices: per-device IP override and explicit
approval workflow before a self-enrolled device can connect.

### Added

- **Admin IP override**. Admin can change a device's tunnel IPv4/IPv6 from the
  device detail page. New `Devices.admin_update_device/4` runs the existing
  CIDR / exclusion / uniqueness validation, calls `Events.set_config/0` to
  resync the running WG peer list immediately, and audits the change. UI shows
  a "Network Configuration" card on the device detail page (admin only) with
  inline edit form + post-save banner reminding the admin that the user must
  sign out and sign in on the NexGuard Connect client to pick up the new
  address locally (`apps/fz_http/lib/fz_http/devices.ex`,
  `apps/fz_http/lib/fz_http/devices/device/changeset.ex`,
  `apps/fz_http/lib/fz_http_web/templates/shared/show_device.html.heex`,
  `apps/fz_http/lib/fz_http_web/live/device_live/admin/show_live.ex`).
- **Device approval workflow**. New native-client enrollments arrive with
  `status="pending"` and are excluded from the WG peer list (`Device.Query.only_active/1`)
  until an admin clicks "Approve Device" in the portal. Pattern matches
  Tailscale's "approve new device" gate. Existing devices created before this
  feature default to `"approved"` (migration default), so no disruption to
  current users; admin-created devices via the portal also default to
  `"approved"` since the admin act IS the approval (only self-enrolled native
  clients start pending).
  - `POST /api/v1/devices/enroll` and `GET /api/v1/devices/me/config`
    responses now carry a `status` field so clients can show a "Pending
    Approval" screen instead of trying to connect.
  - `Devices.approve_device/3` and `Devices.revoke_approval/3` — admin-only,
    update status + stamp `approved_at` + `approved_by_id`, trigger
    `Events.set_config/0` to push the WG kernel update, and audit.
  - Portal UI: status badge per device on the index list, plus an "Approval"
    card on the device detail page with NexGuard-styled confirmation modals
    (no browser-native `window.confirm` — matches the existing delete-device
    modal pattern).
- **Audit log actions**: `device.ip.change`, `device.approve`,
  `device.revoke_approval`. The IP-change audit metadata carries `old_ipv4` /
  `new_ipv4` for forensic.

### Changed

- `Device.Query.only_active/1` now filters by `status == "approved"` in
  addition to user-session and MFA checks. Pending devices are silently
  excluded from the WG peer list — no special handling needed at the tunnel
  level (cryptokey routing rejects them automatically since the peer doesn't
  exist on the kernel interface).

[2.1.0]: https://github.com/0xphuong/NexGuard/compare/v2.0.1...v2.1.0

---

## [2.0.1] - 2026-06-14

MFA support for the native client auth flow introduced in 2.0.0.

### Added

- **MFA challenge for native sign-in**. When a user with at least one
  registered MFA method completes the OIDC step of the native flow,
  `do_sign_in/3` now redirects through the existing web MFA LiveView
  (`/mfa/auth/<last-used-method-id>`) instead of issuing the one-time code
  immediately. After the TOTP verifies, the LiveView redirects to a new
  `GET /auth/native/finalize` controller action which reads the deferred
  `:native_flow` session, creates the auth code, drops the browser session,
  and redirects to `nexguard-connect://callback`. Native clients reuse the
  portal's MFA UI — no native MFA UI required
  (`apps/fz_http/lib/fz_http_web/controllers/auth_controller.ex`,
  `apps/fz_http/lib/fz_http_web/live/mfa_live/auth_live.ex`,
  `apps/fz_http/lib/fz_http_web/router.ex`).
- **`FzHttp.Auth.MFA.has_methods?/1`** helper — quick existence check used by
  the native-flow MFA branch (`apps/fz_http/lib/fz_http/auth/mfa.ex`).

### Notes

- VPN session timer starts only after MFA passes (matches portal behavior):
  `Users.update_last_signed_in/2` is called in the MFA verify handler when
  `require_mfa` is enabled, so the 24-hour native-client refresh window is
  anchored on the MFA moment, not the OIDC moment.
- Native clients did not have to change — server still hands them a one-time
  code at the same `nexguard-connect://callback` URL after MFA.

[2.0.1]: https://github.com/0xphuong/NexGuard/compare/v2.0.0...v2.0.1

---

## [1.3.4] - 2026-06-10

### Fixed

- **Last Handshake shows "Thu, Jan 1, 1970, 8:00 AM" for devices that lost VPN auth** — root cause: WireGuard's `wg show dump` returns `latest_handshake = 0` for peers that have never completed a handshake (e.g. immediately after a peer is re-added when a user re-authenticates). `StatsUpdater.latest_handshake/1` converted the `"0"` string to `DateTime.from_unix!(0)` = `~U[1970-01-01T00:00:00Z]` and `StatsUpdater.update/1` wrote that value into `devices.latest_handshake`, overwriting any previously valid timestamp. If the user's session expired before the next real handshake, the 1970 value stuck in the DB and rendered in UI as "Thu, Jan 1, 1970, 8:00 AM" (UTC+8 / UTC+7 formatting of epoch 0). Four-part fix:
  - `StatsUpdater.latest_handshake("0")` now returns `nil` and the caller skips updating the field, preserving the previous good value (`apps/fz_http/lib/fz_http/devices/stats_updater.ex`).
  - Added `Devices.has_handshaken?/1` helper that treats both `nil` and pre-2000 timestamps as "never connected", so the "Connected / Never connected" badge on the device detail page renders correctly even for legacy rows (`apps/fz_http/lib/fz_http/devices.ex`, `apps/fz_http/lib/fz_http_web/templates/shared/show_device.html.heex`).
  - Defensive guard in `FormatTimestamp` JS helper: any timestamp before year 2000 renders as "Never" (`apps/fz_http/assets/js/util.js`).
  - Migration `20260610000001_clear_epoch_zero_handshakes` clears any existing pre-2000 `latest_handshake` values to `NULL` on deploy.

[1.3.4]: https://github.com/0xphuong/NexGuard/compare/v1.3.3...v1.3.4

---

## [1.3.3] - 2026-06-02

### Fixed

- **Periodic HTTP 431 "Request Header Fields Too Large" requiring browser cache clear** — root cause: OIDC redirect set two one-time cookies (`fz_oidc_state`, `fz_pkce_code_verifier`) but never deleted them after the callback consumed them, in `do_sign_in/3`, on error paths, or on `sign_out`. Combined with a large session cookie (`_fz_http_key` carries the Google `id_token` ~2 KB plus Guardian JWT, base64+encryption overhead → ~4–5 KB) and Cowboy's default `max_header_value_length: 4096`, browsers eventually built a Cookie header that exceeded the limit. Three-part fix:
  - Added `delete_cookie/1` to `FzHttpWeb.OIDC.State` and `FzHttpWeb.OAuth.PKCE`; called from every OIDC exit point — `oidc_callback` success (via `do_sign_in`), `oidc_callback` error branches, and `Authentication.sign_out`.
  - Raised the Cowboy header limit defaults via `:phoenix_http_protocol_options` — `max_header_value_length: 16384`, `max_header_name_length: 256`, `max_headers: 100` — buying ~4× headroom on top of the cleanup.
  - Added `FzHttpWeb.Plug.CookieHygiene` to the `:browser` pipeline. On every non-OIDC-callback request it sends `Set-Cookie: ...; Max-Age=0` for the two transient cookies, force-cleaning any orphans already sitting in user browsers from earlier releases. No re-login required.

[1.3.3]: https://github.com/0xphuong/NexGuard/compare/v1.3.2...v1.3.3

---

## [1.3.2] - 2026-05-29

### Fixed

- **HTTP 500 when admin views user detail page for users with an OIDC connection** — `OIDCLive.ConnectionsTableComponent` template had three top-level elements (modal conditional + page header `<div>` + table wrap `<div>`), violating Phoenix LiveView's "stateful components must have a single static HTML tag at the root" rule; component now wrapped in a single root `<div>`. Symptom appeared non-deterministic — admin could open their own user and a subset of others, but 500'd on the rest — because the parent template at `user_live/show.html.heex:157` skips the component when `@connections == []`, masking the bug for users without an `oidc_connections` row (i.e., users whose Google login never returned a `refresh_token`)

[1.3.2]: https://github.com/0xphuong/NexGuard/compare/v1.3.1...v1.3.2

---

## [1.3.1] - 2026-05-28

### Changed

- **Add Device modal redesigned** — wider layout (640px), advanced WireGuard settings collapsed behind "Advanced settings" toggle (hidden by default); Yes/No radio pairs replaced with `ng-toggle` switches; advanced section expands inline without page scroll
- **Device config result redesigned** — after generating a config: green success banner, amber one-time-view warning, QR code and Download button side-by-side, dark config block with Copy button, Done link to close without X button

### Fixed

- **QR code squished after Generate Configuration** — canvas element was being compressed horizontally inside flex container due to `height: auto` not maintaining aspect ratio on `<canvas>`; fixed with explicit `width: 140px; height: 140px; flex-shrink: 0`
- **"Save" text not centered in modal buttons** (Add Token, Add MFA Method, Add User) — `submit()` helper generated `<input type="submit">` which ignores `display: inline-flex; align-items: center` (no child nodes); replaced with `<button type="submit">` across all modals via shared `submit_button.html.heex`
- **Spinner icon** on config generation was using deprecated Font Awesome class (`fa fa-spinner fa-spin`); replaced with MDI (`mdi mdi-loading mdi-spin`) to match the rest of the design system

[Unreleased]: https://github.com/0xphuong/NexGuard/compare/v1.3.4...HEAD
[1.3.1]: https://github.com/0xphuong/NexGuard/compare/v1.3.0...v1.3.1

---

## [1.3.0] - 2026-05-27

### Added

- **Immutable Audit Log** — new `/settings/audit_log` page records every security-relevant event with actor, action, result, target, IP address, and timestamp; events are append-only (no edit or delete from UI/API)
- **Audit event coverage** — the following event types are captured:

  | Category | Events |
  |---|---|
  | Authentication | `auth.login`, `auth.logout`, `auth.login_failure`, `auth.mfa_success`, `auth.mfa_failure` |
  | Users | `user.create`, `user.update`, `user.delete`, `user.enable`, `user.disable` |
  | Devices | `device.create`, `device.delete` |
  | Rules | `rule.create`, `rule.update`, `rule.delete` |
  | Config | `config.change` |

- **Actor & IP tracking** — all events record the actor email and the originating IP address; events triggered via the REST API use the request IP; LiveView events use the WebSocket remote IP; system events (e.g. auto-expiry) log without actor
- **Target field** — events reference the affected object by type and label (e.g. `user: admin@corp.com`, `device: laptop`, `configuration: system`)
- **Configurable retention policy** — default 90 days; adjustable from 1 to 3650 days directly from the Audit Log settings page; backed by the `configurations` DB table (env var `AUDIT_LOG_RETENTION_DAYS` overrides and locks the UI field)
- **Daily purge** — `FzHttp.AuditLog.RetentionScheduler` GenServer runs once per day and deletes entries older than the configured retention window; reads the live DB value so changes take effect without a restart
- **Filterable log view** — filter by event category (Auth / Users / Config / Devices / Rules) and result (Success / Failure); shows "Showing N of M events" count when a filter is active
- **Paginated table** — 50 events per page with Prev / Next navigation; timestamps formatted client-side to local timezone via `FormatTimestamp` LiveView hook
- New `audit_logs` table (migration `20260527000001`) with `action`, `actor_id`, `actor_email`, `ip_address`, `result`, `target_type`, `target_id`, `target_label`, `metadata` (JSONB), `inserted_at`
- New `audit_log_retention_days` integer column in `configurations` table (migration `20260527000002`), default 90

### UI

- Audit Log page: dense log-console layout — color-coded action badges per category, success/failure icon-only result column, muted type prefix on target column, row hover highlight for cross-column scanning
- Retention Policy panel at bottom of page with explicit input + Save button (replaces previous hidden inline badge form)
- Page header shows read-only `N-day retention` and total event count badges
- Sidebar: **Audit Log** entry added under Settings

[1.3.0]: https://github.com/0xphuong/NexGuard/compare/v1.2.3...v1.3.0

---

## [1.2.3] - 2026-05-27

### Changed
- **Replaced all `data-confirm` (browser native dialogs) with styled LiveView modals** across the entire admin UI — all destructive and role-changing actions now use consistent `modal-card` modals matching the `ng-*` design system; each modal shows the target object (email, device name, provider label, token ID) in a monospace block, lists specific consequences, and supports Escape-to-close and backdrop-click-to-close
- **Refresh Tokens** (OIDC Connections table): removed `data-confirm` entirely — non-destructive action does not require confirmation

### Fixed
- **Delete Your Account** was submitting to `DELETE /sign_out` (session logout only) instead of `DELETE /user` (account deletion) — form action corrected; account is now actually deleted when confirmed

### UI — Modals added

| Action | Location | Pattern |
|---|---|---|
| Delete User | User Detail page | Parent LiveView modal |
| Promote / Demote User | User Detail page | Parent LiveView modal with role transition display (`current → new`) |
| Disable VPN Connection | User Detail page | `VPNConnectionComponent` internal modal — confirm only on disable, enable executes immediately |
| Delete Device | Device Detail page (admin + unprivileged) | Shared template modal, both LiveViews wired |
| Delete OIDC Provider | Security Settings | Single shared modal driven by `pending_delete` assign; title adapts to OIDC vs SAML |
| Delete SAML Provider | Security Settings | (same modal as above) |
| Delete Your Account | Account Settings | Modal gates the form submit to `DELETE /user` |
| Delete MFA Authenticator | Account Settings (admin + unprivileged) | Shared template button, modal in each parent template |
| Delete API Token | Account Settings | Parent LiveView modal showing full token UUID |
| Delete OIDC Connection | User Detail → OIDC Connections | `ConnectionsTableComponent` internal modal with provider-specific warning |

---

## [1.2.2] - 2026-05-27

### Added
- **Security Dashboard Panel** — new two-column layout on the main dashboard; left column displays a Security panel with six live-updated rows: MFA Coverage (percentage of users enrolled), Admin Accounts, Stale Devices (no handshake in 7+ days), VPN Session Duration, Authentication Methods (OIDC / SAML provider counts), and WAN Connectivity status

### Changed
- **VPN session timer starts from MFA completion** — when Force MFA (`require_mfa`) is enabled, `last_signed_in_at` is now set only after the user successfully completes MFA (not at password entry); when Force MFA is disabled the behaviour is unchanged (timer starts at password login)
- `Device.Query.only_active/1`: MFA-aware peer filtering — when `require_mfa` is on and `last_signed_in_at IS NULL` (user never completed MFA), the device is excluded from the WireGuard peer list regardless of `vpn_session_duration`; when `require_mfa` is on and sessions expire, a non-nil `last_signed_in_at` is required in addition to the expiry window check
- `Users.vpn_session_expired?/1`: returns `true` for users with `last_signed_in_at = nil` when `require_mfa` is on, so the VPN Status badge on the User Detail page correctly shows **Expired** instead of **Enabled** for users who have never completed MFA

### Fixed
- **WAN Connectivity badge** always showing "Disabled" when no checks were recorded — `list_connectivity_checks/0` returns a plain list (not `{:ok, list}`); corrected pattern match in dashboard assigns
- **MFA method ownership check** — `MFALive.Auth.handle_params/3` now validates that the requested MFA method belongs to the current user; previously any authenticated user could authenticate with another user's MFA method ID; mismatched ownership now redirects to `/` identical to a not-found result
- Admin-created devices for users who have never signed in no longer connect to VPN when Force MFA is enabled — the `only_active/1` fix above closes this gap

---

## [1.2.1] - 2026-05-26

### Added
- **Preserve Client IP / Internal Subnets UI** — `GATEWAY_NO_MASQUERADE_CIDRS` is now fully configurable from the **Network** settings page (new dedicated page separate from Client Defaults); toggle "Preserve Client IP" to enable no-NAT mode, with a textarea to customise the internal subnets (defaults: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`); changes hot-reload the nftables postrouting chain without restart
- New `gateway_no_masquerade_enabled` boolean column and `gateway_no_masquerade_cidrs` text column in the `configurations` table (migration `20260525000002`)
- When `GATEWAY_NO_MASQUERADE_ENABLED` or `GATEWAY_NO_MASQUERADE_CIDRS` env vars are set, the corresponding UI fields are locked with a clear "Locked by env var" badge and explanation
- `FzWall.Server.reload_masquerade/0` — GenServer call that flushes and rebuilds only the nftables `postrouting` chain from the current DB config value

### Changed
- Moved Preserve Client IP and Internal Subnets settings from Client Defaults to the new **Network** page (`/settings/network`) — these are server-side gateway/NAT settings, not WireGuard client defaults
- `fz_wall/nft.ex`: masquerade rules now read live from `FzHttp.Config.fetch_config!` at reload time instead of frozen boot-time Application env
- `runtime.exs`: removed `no_masquerade_cidrs` from `:fz_wall` app env (now read live from `FzHttp.Config`)

### UI
- Complete `ng-*` design system migration across all admin modal forms: OIDC, SAML, Add Device, Add API Token, MFA registration, Edit User, Show API Token
- New form component CSS: `ng-field`, `ng-label`, `ng-input`, `ng-textarea`, `ng-field-error`, `ng-field-hint`, `ng-input-group`, `ng-input-suffix`, `ng-toggle-row`, `ng-radio`, `ng-radio-group`
- Replaced all Bulma flash notifications with `ng-flash` / `ng-flash--info` / `ng-flash--error` components
- Replaced all `switch is-medium` toggles with `ng-toggle` across Security, OIDC, SAML, VPN connection components
- OIDC Connections table migrated to `ng-table` / `ng-secondary-btn` / `ng-danger-btn`
- `.is-main-section` given explicit `padding: 1.5rem` so page content is not Bulma-dependent

### Fixed
- `show_api_token_component`: removed Bulma `level`, `title is-6`, `button`, `block` — now uses `ng-label`, `ng-secondary-btn`, `ng-flash--info`, `ng-inline-link`
- Edit User modal form: replaced `field`/`control`/`label`/`help is-danger` with `ng-field`/`ng-label`/`ng-input`/`ng-field-error`

---

## [1.2.0] - 2026-05-25

### Added
- **No-NAT Subnets UI** — `GATEWAY_NO_MASQUERADE_CIDRS` is now configurable from the admin panel (Client Defaults → No-NAT Subnets) in addition to the environment variable; changes take effect immediately without a restart via a hot-reload that flushes and rebuilds only the nftables `postrouting` chain
- New `gateway_no_masquerade_cidrs` text column in the `configurations` table (migration `20260525000002`); env var continues to work as an override and locks the UI field when set
- `FzWall.Server.reload_masquerade/0` — new GenServer call that flushes the postrouting chain and re-applies RETURN + masquerade rules from the current database value

### Changed
- `fz_wall/nft.ex`: `setup_no_masquerade_rules/0` now reads `FzHttp.Config.fetch_config!(:gateway_no_masquerade_cidrs)` at runtime instead of the frozen `Application.fetch_env!` value set at boot; `reload_postrouting/0` added for hot-reload
- `runtime.exs`: removed `no_masquerade_cidrs` from the `:fz_wall` application env block (value is now read live from `FzHttp.Config`)

---

## [1.1.2] - 2026-05-25

### Added
- **Force MFA** global toggle in Security settings: when enabled, all users without an MFA method are redirected to the enrollment page on next sign-in and blocked from the REST API (`/v0`) until they enroll
- New `require_mfa` boolean column in the `configurations` table (migration `20260525000001`)
- New plug `FzHttpWeb.Plug.RequireMFA` added to the `:api` pipeline — returns `403` with a JSON error when Force MFA is on and the API user has no MFA method registered

### Changed
- `LiveMFA` hook: when Force MFA is enabled and a user has no MFA methods, redirects admin to `/settings/account/register_mfa` and unprivileged users to `/user_account/register_mfa` instead of continuing; MFA registration routes are excluded from enforcement to prevent redirect loops
- Redesigned MFA verification screen (`/mfa/auth/:id`): `auth-card` layout matching the login page, monospace OTP input with `one-time-code` autocomplete, "Use a different authenticator" back link
- Redesigned MFA method selector screen (`/mfa/types`): `auth-card` layout, each method displayed as an `auth-provider-btn` card consistent with the SSO provider buttons on the login page

---

## [1.1.1] - 2026-05-25

### Changed
- Redesigned User Detail page (`/users/:id`): page header with avatar, role badge, VPN status; profile and devices in card layout; danger zone with proper labels and descriptions
- Redesigned Device Detail page (`/devices/:id`, `/user_devices/:id`): page header with connection status badge; transfer stats (Received / Sent / Latest Handshake); details grouped into Network and WireGuard Configuration cards; danger zone
- Redesigned unprivileged Devices page (`/user_devices`): consistent page header with Add Device button; VPN Session card replacing the old inline level layout
- Breadcrumb on Device Detail is now context-aware: admin sees user email link, unprivileged user sees "My Devices" link
- `README.md`: updated Quick Start commands; added tip for resetting admin manually with `bin/create-or-reset-admin`
- `CHANGELOG.md`: added standard changelog following Keep a Changelog format

### Fixed
- `WIREGUARD_IPV4_ADDRESS` in `.env.example` documented as plain IP, not CIDR
- `PHOENIX_HTTP_PORT` corrected (was `PHOENIX_PORT`); `OUTBOUND_EMAIL_ADAPTER` corrected (was legacy `OUTBOUND_EMAIL_PROVIDER`)

---

## [1.1.0] - 2026-05-25

### Added
- Full NexGuard branding applied to admin UI, web manifest, and omnibus packages
- Proper `.env.example` with all supported environment variables documented

### Changed
- Admin UI redesigned: login page, main dashboard, navbar, sidebar menu
- Redesigned pages: Users, Devices, Rules, Settings (Security, Config, Account, Notifications, Customization)
- Omnibus cookbook and packaging migrated to `nexguard` namespace

---

## [1.0.2] - 2026-05-25

### Fixed
- Connectivity check configuration not applying correctly on fresh installs

---

## [1.0.1] - 2026-05-24

### Fixed
- Login page UI rendering incorrectly on certain screen sizes

---

## [1.0.0] - 2026-05-24

### Added
- Self-hosted VPN server built on WireGuard® and nftables (forked from Firezone 0.7)
- Web admin UI for managing users, devices, and egress firewall rules
- SSO support via OpenID Connect (OIDC) and SAML 2.0
- Per-user and global egress rules using Linux nftables
- Docker Compose and Omnibus package deployment methods
- REST API for programmatic management
- Multi-factor authentication support
- Connectivity checks and telemetry (opt-out supported)
- Automatic TLS via Caddy reverse proxy

[1.2.3]: https://github.com/0xphuong/NexGuard/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/0xphuong/NexGuard/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/0xphuong/NexGuard/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/0xphuong/NexGuard/compare/v1.1.2...v1.2.0
[1.1.2]: https://github.com/0xphuong/NexGuard/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/0xphuong/NexGuard/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/0xphuong/NexGuard/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/0xphuong/NexGuard/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/0xphuong/NexGuard/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/0xphuong/NexGuard/releases/tag/v1.0.0
