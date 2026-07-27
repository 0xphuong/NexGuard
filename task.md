# Task list — NexGuard server

Last updated: 2026-07-27 · Server at **v3.3.0** · Pairs with NexGuard Connect macOS **v0.5.9** / Windows **v0.6.2** / Linux CLI **v0.3.1**

For the full feature history see [CHANGELOG.md](CHANGELOG.md). For the matching
client task list see [`nexguard-connect/task.md`](https://github.com/0xphuong/nexguard-connect/blob/main/task.md).

---

## ✅ Done — recent

The `2.x` line introduced native auth + admin features for the NexGuard
Connect client. Headline releases:

| Version | Highlights |
|---|---|
| **v3.0.9** (2026-06-28) | **Admin portal UX sweep** — `frontend-design-direction` applied to every major surface across 24 commits: `/devices`, `/rules`, `/applications`, `/access-groups`, `/settings/{certificates, l7, security, account, network, audit_log, client_defaults, customization}`, `/diagnostics/connectivity_checks`, `/notifications`. Recurring patterns: stats strip + status callout up top, filter bars on indexes, 4-zone Overview cards on show pages, confirm modals for blast-radius toggles (Force MFA, Local Auth, masquerade, DNS save, no-MASQ enable), lock-out guards on SSO + MFA delete, computed warnings instead of conditional-in-prose, aria-label replaces hover-only `title=`, ~150 inline `style="..."` declarations → utility classes. Safety + correctness fixes uncovered along the way: `FzWall.CLI.Live.reload_postrouting/0` delegate (was crashing network settings on every save), `FzHttp.Validator.validate_cidr_list/3` (so `10.0.0.0` without `/N` no longer slips into nftables), `Devices.get_dns/2` auto-forces gateway CoreDNS when L7 is on (clients pointed at upstream DNS were NXDOMAINing every declared L7 hostname). New design tokens: `.ng-modal-callout--danger`, `.ng-cert-status-badge` family, `.ng-rule-action-badge--allow/--deny`, `.ng-conn-cell` family, `.ng-stat-tile--{danger,warn,ok,muted}`, `.ng-toggle-state(--on)`, `.ng-row--{pending,stale,failure}`, plus scoped `.ng-detail-card-header .ng-section-header { margin: 0 }` that kills 20+ inline `style="margin: 0"` overrides codebase-wide |
| **v3.0.8** (2026-06-26) | **Users domain redesign** — full refresh of `/users`, `/users/:id`, and the add/edit user modal. Index gains a stats strip (Total / Active-24h / MFA-enrolled% / Admin / Break-glass), MFA-freshness column (`✓ 5m` / `⚠ 45d` / `?` / `—` driven off `User.Query.hydrate_index/1`), filter bar (email search + Role + MFA + Status chips), bulk actions (Disable / Enable / Delete with confirm modal). Show page picks up a 3-line hero, 4-zone Overview card, and 6 URL-addressable tabs (Overview / Devices / Groups / Access / Connections / Danger) with the Edit + Add-Device modals overlaying. Add/Edit user modal harmonised — email field + password inputs all in the `.ng-field` family, amber callout warning that email change may break OIDC/SAML linkage, "Leave blank to keep current password" hint, per-action submit copy ("Create user" vs "Save changes"). Removed: VPN Status column + Created column on index. Deferred: U-Show-C (modal partial extraction) needs a function-component refactor; E-Form-B/C opt-in follow-ups |
| **v3.0.2** (2026-06-24, on prod, untagged) | ADR-015 **shared TLS certificate library**. Admins upload each wildcard / multi-SAN cert ONCE at `/settings/certificates`; L7 apps pick by `tls_cert_id` (explicit pin) or hostname → SAN auto-match via `FzHttp.L7.CertResolver`. Renewals are one-click in-place replace — every app pointing at the row rolls over on the next bundle pivot. New `l7_tls_certificates` table + `cert_source = :library`, daily `TlsCertExpiryScanner` (30d / 7d / expired thresholds with audit dedupe), `CertParser` enforcing RSA ≥2048 / ECDSA P-256+ / cert↔key match. **Applications hardening PR**: close enable-bypass via `update_application(%{"enabled" => true})`, capture full per-field diff in `application.update` audit metadata (l7_rules + cert config visible), explicit `@permitted_update` list replaces brittle `--` subtraction. ~3000 LoC + 30 test cases |
| **v3.0.1** (2026-06-24, on prod, untagged) | Security hardening + DNS / runbook fixes. **Proxy**: strip client-sent `X-Forwarded-*` before forward + canonical add-back, path normalization (`..` and double-slash rejected before policy eval), JWT signature redaction in logs, PEM zeroed in memory after parse, `WriteHeader` guard. **JWT**: `iss=nexguard-proxy` + `aud=<app uuid>` + `jti` + `nbf` claims — backends MUST validate `iss` and `aud` (see `docs/migrations/v3.0.1.md`). **Audit**: whitelist 12 missing L7 / app / group / scope actions + regression test pin. **CoreDNS**: `fallthrough .` fix for sister names under declared zones, optional `COREDNS_FORWARD_TO_FALLBACK` for bind9 HA pair, cache hardening (`serve_stale 1h immediate` + `prefetch 10 1m 10%` + 16K success cap + 4K denial 5min), template plugin NXDOMAINs `.local/.lan/.home/.internal/.corp` locally |
| **v3.0.0** (2026-06-21) | L7-D — L7 transparent proxy daemon GA. Custom Go binary (`proxy/`, ~5 KLOC, distroless ~20 MB image): IP_TRANSPARENT TLS listener, bundle/identity HTTP clients with TTL cache, RS256 JWT signer, first-match-wins policy evaluator, reverse proxy with backend-scheme allow-list + outbound TLS 1.2 pin + reserved-header response scrub, Prometheus metrics + structured access log + /healthz + /readyz. Server-side: bundle now carries `signing_key.private_pem` + per-app `key_pem`; `/internal/*` HARD-404'd at public :443; new Caddy :13443 mTLS site enforces `require_and_verify` against operator-provisioned `scripts/l7-rotate-proxy-cert.sh` CA. Independent security review: 2 critical + 4 high fixed inline. Perf: 1143 rps / p99 21 ms |
| **v2.4.0** (2026-06-21) | L7-C network plumbing: `FzWall.CLI.Helpers.Tproxy` installs `l7_prerouting` nftables chain on `:l7_enabled_changed` (TPROXY to `127.0.0.1:8443`), fwmark + loopback routing primitives installed at every fz_wall boot, `FzHttp.L7.CoreDnsHosts` GenServer writes `/etc/nexguard/internal-hosts` atomically on every Applications mutation, opt-in `docker-compose.coredns.yml` overlay with CoreDNS 1.11 sidecar + Corefile. Dormant by default — keep `l7_enabled = false` until L7-D's proxy daemon ships |
| **v2.3.0** (2026-06-21) | L7-B Phases 1–5: JWT signing infrastructure (`l7_signing_keys` + bootstrap), `GET /.well-known/jwks.json`, `GET /internal/sessions/by_vpn_ip/:ip` (identity payload + ETag + 30 s cache), `FzHttp.L7.BundleBuilder` (debounced signed bundle compile + ETS LKG ring), `GET /internal/bundle.json` (ETag + `?since` long-poll), `nexguard:l7:{groups,identity,bundle}` PubSub wiring. Phase 6 (mTLS) deferred to L7-D so cert provisioning ships with the proxy daemon that consumes it. Endpoints exist but no consumer yet |
| **v2.2.0** (2026-06-21) | L7-A: admin data + UI for upcoming L7 proxy — access groups + applications with full L7 rules editor + cert upload + org kill switch. Proxy ships dormant in 2.2.0; data plane lands in L7-B → L7-F |
| **v2.1.1** (2026-06-19) | Admin notifications for pending device approvals — in-portal badge + Notifications page fire on enrollment, auto-clear on approve/revoke/delete |
| **v2.1.0** (2026-06-14) | Admin IP override (per-device IPv4/IPv6) + device approval workflow (`status: pending → approved`) |
| **v2.0.1** (2026-06-14) | MFA support for native client flow (reuses portal MFA challenge) |
| **v2.0.0** (2026-06-13) | Native auth (T1-T7): DB foundation, browser bridge, token endpoints, device enrollment, sign-out + revoke |
| **v1.3.x** | Stability + nftables port-range rules; final pre-2.x line |

---

## ⏳ Pending — ready to implement when prioritized

### 🆕 Carryover from v3.0.9 UX sweep

Items each redesign-pass intentionally deferred, grouped by domain. Most
are Pass-2-or-later work that needs either a backend endpoint, schema
change, or design discussion before another template edit pays off.

| ID | Surface | Task | Effort | Notes |
|---|---|---|---|---|
| **UX-1** | `/settings/security` | OIDC + SAML form-component harmonisation | ~1h | Bring the two SSO form modals up to the user/app form pattern — `phx-change="validate"`, `.ng-field` family, `.ng-modal-callout` upfront disclosure. Defer-able while the rest of the security page communicates state well |
| **UX-2** | `/settings/security` | MFA freshness window (`require_mfa_age_seconds` org-wide) UI surface | ~2h | The field already gates L7 rules per-app; org-wide value would set the default ceiling for everyone |
| **UX-3** | `/settings/account` | Sign-out other sessions affordance | ~2-3h | Needs `Sessions.list_by_user/1` + bulk-invalidate; current Presence is read-only and ephemeral |
| **UX-4** | `/settings/audit_log` | CSV / JSON export endpoint | ~2h | Compliance reviewers' ask — new controller route gated by `:api` pipeline; filter params come from the URL |
| **UX-5** | `/settings/audit_log` | Live tail via PubSub | ~2h | New `AuditLogs.subscribe/0` broadcast at insert + LV `stream_insert` on the existing table |
| **UX-6** | `/settings/audit_log` | Severity tag on destructive actions | ~1h | Classifier: `*.disable / .delete / role.change / .revoke` → red; `*.create` → neutral; etc. Drives `.ng-row--*` tint |
| **UX-7** | `/settings/audit_log` | Diff "hide unchanged" toggle | ~30min | `application.update` payloads carry 20+ keys; current diff shows them all |
| **UX-8** | App-wide | DRY refactor of repeated 3-clone confirm modals | ~2h | Inline `<.confirm_modal>` function component once Phoenix LV 0.18+ embed_templates pattern feels stable. Tag against any future page that introduces yet another confirm |
| **UX-9** | App-wide | Toggle-row function component | ~1.5h | 5 near-identical settings-row blocks on `/settings/security` + variants on `/settings/network`. Consolidate when next polish touches either page |
| **UX-10** | `/settings/customization` | URL-mode logo live preview | ~30min | Paste URL → preview before save. Needs `phx-change` + image preload + debounce |
| **UX-11** | `/applications` | `Applications.subscribe()` on Index + Show | ~30min | Multi-admin staleness. Same pattern in the new `setting_live/certificates_live.ex`. Tracked as **R6** below too |

---

#### UX-12 — Internal mTLS cert expiry monitoring (3 options, awaiting decision)

`/var/nexguard/l7-certs/` holds the L7 control-plane certs (CA +
server + proxy client) generated by
`scripts/l7-rotate-proxy-cert.sh`. CA = 10y, leafs = 1y. The
existing `TlsCertExpiryScanner` only checks DB-stored library certs,
so these on-host certs are an **observability blind spot** — admin
must self-monitor. Three approaches, pick by appetite:

##### Level 1 — Host cron script (~10 min, zero code change)

Drop the snippet already in `docs/migrations/v3.0.0.md` (Cert
lifecycle § Suggested cron) into `/etc/cron.daily/`. Webhook to
Slack/Discord when any cert is within 30 days of `notAfter`.

  * ✅ Setup ~10 min
  * ✅ Works on any host with openssl + curl
  * ❌ Lives outside the application — separate maintenance loop
  * ❌ Doesn't surface on `/notifications` or audit log
  * ❌ Webhook URL stored in script (or systemd env file)

##### Level 2 — Phoenix integration (~45 min) **← recommended**

Extend the existing monitoring pipeline:

  1. Bind-mount the 3 `.pem` files (read-only) into the nexguard
     container — public certs only, NO `.key` files.
  2. New module `FzHttp.L7.MtlsCertExpiryScanner` (~80 LoC),
     parallel to `FzHttp.L7.TlsCertExpiryScanner` shipped in
     ADR-015. Reads files, parses with X509 lib, emits via the
     same Notifications + AuditLogs channels at 30d / 7d / expired
     thresholds (with dedupe).
  3. Add to `:full` supervision tree.
  4. Tests (~40 LoC) with mocked cert files + known expiry stamps.
  5. Whitelist `tls_cert.mtls_expiring` action in AuditLog
     changeset.

  * ✅ Notif badge + audit log automatic — admin sees expiry inside
    the portal, no Slack scrolling
  * ✅ Survives deployment (compose-level mount)
  * ✅ Mirror of an existing, well-tested module — low novelty
  * ⚠️ Phoenix container reads CA *public* cert PEM (minor
    exposure — no new secret, since `.key` files stay out)
  * ⚠️ Requires compose volume edit + container restart

Webhook (Slack/Discord) still possible as an additional side-effect
handler on top — flexible.

##### Level 3 — Sidecar Docker container (~30 min)

Add a small alpine container running `crond -f` with the same
script as Level 1, bind-mounting `/var/nexguard/l7-certs/` read-only.

  * ✅ Isolated — Phoenix container untouched
  * ✅ Easy to replace (edit script + `docker compose restart`)
  * ❌ Doesn't surface on `/notifications` or audit log
  * ❌ +1 container in the compose surface area

##### Comparison

| Aspect | L1 (host cron) | L2 (Phoenix integration) | L3 (sidecar) |
|---|---|---|---|
| Setup time | 10 min | 45 min | 30 min |
| Code change | 0 | +120 LoC | +1 compose service |
| In `/notifications` page | ❌ | ✅ | ❌ |
| In audit log | ❌ | ✅ | ❌ |
| Slack/Discord webhook | ✅ native | ⚙️ add handler | ✅ native |
| Survives host reinstall | ❌ | ✅ | ✅ |
| Maintenance burden | Admin owns script | NexGuard codebase | Admin owns compose entry |

##### Recommendation

**Level 2** — observability lands in the same place as every other
L7 cert health signal (`/notifications` + audit), and the module
mirrors a pattern already proven in production
(`TlsCertExpiryScanner` from v3.0.2). Webhook can be layered on
top.

**Fallback**: Level 1 if Phoenix changes are out of scope for the
sprint. Skip Level 3 — not enough value over Level 1 to justify
the extra container.

---

### 🚧 ZTNA L7 — Phase 5 next (operations polish)

Layer 7 identity-aware access. L3/L4 enforcement is shipped (nftables
+ WG); L7 adds HTTP-method / path / header / MFA-age policy via a
TLS-terminating transparent proxy in front of managed apps. Full
architecture in [`docs/decisions.md`](docs/decisions.md) ADR-007 →
ADR-014 and [`nexguard-connect/SPEC.md` §8](https://github.com/0xphuong/nexguard-connect/blob/main/SPEC.md#8-gateway-l7-architecture).

**Locked design** (chốt 2026-06-19):
- **Scope**: L7 enforces **only on declared internal-domain apps**;
  public-internet traffic bypasses the proxy and stays on L4
  enforcement (ADR-014). Per-org `l7_enabled` toggle = kill switch.
- Proxy: custom Go binary (ADR-007)
- Policy language: inline JSONB rules, first-match, default deny; OPA Rego deferred (ADR-008)
- TLS: terminate by default; passthrough deferred to v2 (ADR-009)
- **Per-app cert source**: `upload` OR `step_ca` (ADR-011 + ADR-014)
- Identity propagation: plain headers + RS256-signed JWT, IAP-style (ADR-010)
- Internal CA: smallstep `step-ca`, ACME-issued 90-day leafs — conditional (ADR-011)
- DNS: CoreDNS hosts plugin, **selective override** only (ADR-012)
- Policy distribution: Phoenix-pulled JSON bundle + PubSub invalidation (ADR-013)
- ext_authz gRPC interface: **document only**, not v1

| ID | Phase | Scope | Effort | Tag | Status |
|---|---|---|---|---|---|
| **L7-A** | Foundation | DB schema + contexts + admin UI for groups, apps, L7 rules editor, org toggle | 5-7 days | server `v2.2.0` | ✅ **shipped 2026-06-21** |
| **L7-B** | Identity API + bundle | `/internal/sessions/by_vpn_ip/{ip}` + `/internal/bundle.json` (signed); Phoenix.PubSub broadcasts | 3-5 days | server `v2.3.0` | ✅ **shipped 2026-06-21** (Phase 6 mTLS deferred to L7-D) |
| **L7-C** | Network plumbing | nftables TPROXY chain extending `fz_wall` (toggles on `l7_enabled`); CoreDNS deploy with hosts plugin + reload | 3-4 days | server `v2.4.0` | ✅ **shipped 2026-06-21** |
| **L7-D** | L7 Proxy core | Custom Go binary: `IP_TRANSPARENT` listener, `SO_ORIGINAL_DST`, identity cache, group + rule eval, JWT header inject, reverse proxy | 7-10 days | server `v3.0.0` | ✅ **shipped 2026-06-21** |
| **L7-E** | Operations | Hot-reload bundle (atomic swap + LKG), audit log integration, branded deny pages, JWT signing key rotation, kill-switch handling | 2-3 days | server `v3.0.1`+ | 🚧 **partial** — atomic swap ✅, base deny redesign ✅, kill switch (l7_enabled) ✅; audit-DB for proxy events / per-org branded customization / rotation UI button still pending |
| **L7-F** | Internal CA (conditional) | smallstep `step-ca` sidecar, ACME automation, root + intermediate, leaf per app — **only if any app sets `cert_source: step_ca`** | 3-4 days | server `v3.1.0` | ⏳ |
| **L7-G** | Client integration (conditional) | NexGuard Connect auto-installs internal CA root via `Security.framework`; MDM `.mobileconfig` documented | 1-2 days | client `v0.1.0` | ⏳ |

**Total remaining**: ~2.5-4 weeks dev + ~1-2 weeks integration testing.

**Risks tracked** in [`docs/decisions.md`](docs/decisions.md):
TPROXY edge cases (asymmetric routing, IPv6) · smallstep CA outage ·
bundle compile latency at scale · browser cert trust UX · custom
proxy security bugs.

---

#### L7-B detailed checklist — Identity API + bundle compile (server `v2.3.0`, ~3-5 days)

**Scope reminder**: pure Phoenix work — no daemons deployed yet. Adds the two HTTP endpoints the future L7 proxy (L7-D) will read from. Output is mTLS-only.

##### Phase 1 — JWT signing infrastructure (~0.5 day)

- [x] **B-1**: migration `20260621000001_create_l7_signing_keys` — `id` UUID, `kid` (unique), `algorithm` default `RS256`, `private_pem :binary` (Cloak-encrypted at app layer), `public_pem :text`, `active boolean`, `rotated_at`, partial unique index on `active = true` enforces single-active-key invariant
- [x] **B-2**: `FzHttp.L7.SigningKey` schema (private_pem via `FzHttp.Encrypted.Binary`) + `FzHttp.L7.JwtSigner` GenServer with cold-boot bootstrap, `sign/2`, `verify/1`, `active_kid/0`, `jwks/0`, `rotate/2`. Grace window = last 3 rotated keys held in memory for in-flight token verification. Added to `:full` supervision tree after `FzHttp.Auth`
- [x] **B-3**: `FzHttp.L7.JwtSigner.rotate/3` — function shipped in B-2; B-3 added optional `name:` opt on `start_link` (mirrors `FzHttp.Notifications`) so tests can spawn isolated instances under `start_supervised!/1`. Coverage in `test/fz_http/l7/jwt_signer_test.exs`: bootstrap, sign/verify round-trip, expired + tampered rejection, rotate + grace verify, subject-attributed audit row. Whitelist `l7.signing_key.{bootstrap,rotate}` actions in `AuditLog.changeset/2` (fix `366b084`)
- [x] **B-4**: `FzHttpWeb.WellKnownController.jwks/2` mounted at `GET /.well-known/jwks.json` under `:api_public` pipeline (unauthenticated by design — public keys + chicken-egg with mTLS). `Cache-Control: public, max-age=300` matches `@grace_size = 3` so a stale proxy cache still verifies in-flight tokens until refresh. Tests in `test/fz_http_web/controllers/well_known_controller_test.exs` cover JWKS shape, cache header, post-rotate exposure of active + grace keys, anonymous reachability

##### Phase 2 — Identity API (~1 day)

- [x] **B-5**: `FzHttp.L7.Identity.lookup_by_vpn_ip/1` returns `{:ok, identity, cache_meta}` or `:not_found`. Cache meta carries `user.updated_at` for ETag (kept out of the wire payload so the identity map remains a strict projection of public fields)
- [x] **B-6**: Single preloaded `from(d in Device, where: d.ipv4 == ^inet or d.ipv6 == ^inet, preload: [user: :groups])`; multi-match falls through the `with` clause to `:not_found`. Also fail-closes on `user.disabled_at != nil`
- [x] **B-7**: `mfa_age_seconds` = `DateTime.diff(now, last_signed_in_at)` when `Repo.exists?(mfa_methods where user_id = ?)`; nil when no MFA method (timestamp would reflect password-only sign-in) or when `last_signed_in_at` is nil
- [x] **B-8**: `FzHttpWeb.Internal.IdentityController.show/2` mounted at `GET /internal/sessions/by_vpn_ip/:ip` under new `:api_internal` pipeline (placeholder; Phase 6 B-27 inserts the mTLS plug)
- [x] **B-9**: 404 + `{"error":"unknown_vpn_ip"}` on unparseable / unknown / disabled / multi-match
- [x] **B-10**: `Cache-Control: private, max-age=30` + weak ETag `W/"md5(user_id:user.updated_at)"`. `If-None-Match` returns 304. PubSub topic `nexguard:l7:identity` (Phase 5 B-23) handles group/scope mutations that don't move `updated_at`
- [x] **B-11**: `test/fz_http/l7/identity_test.exs` — IPv4 + IPv6 lookup, 404 paths, disabled-user fail-close, group projection, MFA-age three branches. Plus `test/fz_http_web/controllers/internal/identity_controller_test.exs` for the HTTP layer (cache header + 304 + etag invalidation)

##### Phase 3 — Bundle compile (~1-1.5 days)

- [x] **B-12**: `FzHttp.L7.BundleBuilder` GenServer (`apps/fz_http/lib/fz_http/l7/bundle_builder.ex`) subscribes to `nexguard:l7:{apps,settings,groups}` and added to `:full` supervision tree right after `JwtSigner` (compile depends on `JwtSigner.jwks/0` + `OrgSettings.l7_enabled?/0`)
- [x] **B-13**: `Process.send_after(self(), :compile, 300)` per event, prior timer canceled — a burst coalesces to one compile 300 ms after the last event
- [x] **B-14**: Bundle map matches task.md shape with `inject_headers`/`strip_headers` emitted as `[]` since the `applications` schema doesn't carry them yet — projection picks them up automatically when the columns land
- [x] **B-15**: `X-NexGuard-Bundle-Signature` = JWT with `bundle_sha256` claim signed by `JwtSigner.sign/2` (`expires_in: 3600`). Pragmatic alternative to RFC 7797 detached JWS — proxy verifies the JWT, then compares the claim to its own SHA-256 of the body
- [x] **B-16**: Named, `:public`, `read_concurrency: true` ETS table `:l7_bundle` — `{:current, entry}` for hot read + `{{:history, n}, entry}` LKG ring (last 3 versions) for proxy rollback
- [x] **B-17**: `:ets.update_counter(table, :version_counter, 1, {:version_counter, 0})` for atomic monotonic version; broadcasts `{:bundle_updated, version}` on `nexguard:l7:bundle` after ETS write

##### Phase 4 — Bundle endpoint (~0.5 day)

- [x] **B-18**: `FzHttpWeb.Internal.BundleController.show/2` mounted at `GET /internal/bundle.json` under the same `:api_internal` pipeline as IdentityController. Reads `BundleBuilder.current/0` straight from the public ETS table — no GenServer hop on the hot path. 503 + `{"error":"bundle_not_compiled"}` when the table is empty
- [x] **B-19**: Body = raw `bundle_json`, headers `ETag: "v<N>"` + `X-NexGuard-Bundle-Signature: <jwt>`. `If-None-Match` matching the current ETag returns 304 with the same headers (no body) so the proxy can refresh its TTL without reading the bundle
- [x] **B-20**: `?since=N` (integer): 304 when `current_version <= N`. Garbage values are ignored and the body is served — proxy never silently misses an update due to a malformed query string
- [x] **B-21**: `test/fz_http_web/controllers/internal/bundle_controller_test.exs` covers empty-state 503, body + signature + ETag, signature verification against SHA-256 of body, If-None-Match 304 + 200 fallthrough, `?since` boundaries, and ETag change after recompile

##### Phase 5 — PubSub broadcast wiring + identity invalidation (~0.5 day)

- [x] **B-22**: `FzHttp.AccessGroups.{create,update,delete}_group` + `{add,remove}_member` now broadcast `:groups_changed` on `nexguard:l7:groups`. Public `subscribe_groups/0` mirrors the convention `Applications`/`OrgSettings` already established
- [x] **B-23**: `Users.update_user/4` (only when role differs) + `Users.set_access_scope/4` (only on real change) + `AccessGroups.{add,remove}_member/4` now call `FzHttp.L7.broadcast_identity_change/1` to fan out `{:identity_updated, vpn_ip}` per affected VPN IP
- [x] **B-24**: New module `FzHttp.L7` with `broadcast_identity_change/1` — preloads `:devices`, flat-maps ipv4 + ipv6, drops nils, emits one event per unique IP on `nexguard:l7:identity`. Includes `subscribe_identity/0` for proxy/test consumers
- [x] **B-25**: `NEXGUARD_LOGIC.md` §17 extended with a PubSub topics table (source vs downstream) plus an L7-B HTTP endpoints table covering JWKS, identity, and bundle

##### Phase 6 — mTLS internal scope (shipped via L7-D v3.0.0, different implementation)

The original plan was a Phoenix-side `:mtls_internal` pipeline that
verified the client cert at the Cowboy layer. The L7-D v3.0.0
release ships mTLS via the **edge proxy (Caddy) instead** — same
threat model coverage with simpler operations:

- [x] **B-26 (alt)**: Caddy `:13443` site in `docker-compose.prod.yml`
  enforces `tls.client_auth { mode require_and_verify
  trusted_ca_cert_file internal-ca.pem }` and reverse-proxies to
  Phoenix on the bridge net. No Phoenix-side router scope change
  required — every existing `/internal/*` route is gated at the
  edge.
- [x] **B-27 (alt)**: Caddy itself does cert verification; no
  `FzHttpWeb.Plugs.MtlsInternal` plug needed. Phoenix trusts that
  the bridge-net request originated from Caddy after it passed
  mTLS validation.
- [x] **B-28 (alt)**: Cert generation handled by
  `scripts/l7-rotate-proxy-cert.sh` (openssl-driven, no `mix`
  task — `mix` runs inside the Phoenix container which has no
  need to touch its own CA root). Internal CA stored on the host
  filesystem at `${FZ_INSTALL_DIR:-.}/l7-certs/`.
- [x] **B-29**: `/.well-known/jwks.json` stays on the public :443
  listener (it's behind the existing `:api_public` Phoenix
  pipeline); the public Caddy block 404s `/internal/*` but lets
  the well-known path through.
- [x] **B-30**: `docs/migrations/v3.0.0.md` "Cert lifecycle"
  section covers proxy cert provisioning + rotation + rollback.

##### Phase 7 — Polish + release (~0.5 day)

- [x] **B-31**: `CHANGELOG.md` `[2.3.0]` entry — covers JWT signing infrastructure, identity API, bundle compile + endpoint, PubSub wiring, the audit whitelist fix, and the error_view 404-renderer fix
- [x] **B-32**: `NEXGUARD_LOGIC.md` §17 extended with PubSub topics table, L7-B HTTP endpoints table, identity payload shape, and bundle JSON schema reference
- [x] **B-33**: `docs/migrations/v2.3.0.md` runbook — `l7_signing_keys` migration + verification steps for JWKS / identity / bundle endpoints + audit row check. No `mix nexguard.l7.bootstrap_keys` task needed — `JwtSigner` bootstraps automatically on first `init/1`
- [ ] **B-34**: Update Obsidian `Roadmap.md` + `L7-Architecture.md` with L7-B shipped — **manual step (outside repo, in personal vault)**
- [x] **B-35a**: Bump `Dockerfile.prod` `ARG VERSION` `2.2.0` → `2.3.0`
- [ ] **B-35b**: Tag `v2.3.0` + push to `origin` + bump `nexguard-releases/versions.json` — **manual step** (push requires explicit user authorization)

##### Acceptance criteria

- [ ] Admin can hit `GET /.well-known/jwks.json` from any client → returns JWKS JSON with active key
- [ ] Proxy with valid client cert hits `GET /internal/sessions/by_vpn_ip/100.64.0.5` → identity payload OR 404
- [ ] Proxy with valid client cert hits `GET /internal/bundle.json` → signed bundle with `apps` and `groups` arrays
- [ ] Admin toggles L7 via `/settings/l7` → bundle recompiles within 300 ms → `bundle_version` increments → PubSub `{:bundle_updated, N+1}` broadcast received by test subscriber
- [ ] Admin adds user to group → `{:identity_updated, vpn_ip}` broadcast received (when that user has an active VPN device)
- [ ] Anonymous (no client cert) request to `/internal/bundle.json` → 401
- [ ] **No proxy / CoreDNS / step-ca process running** — endpoints exist but L7 enforcement still dormant

##### Dependencies

- **Blocked by**: nothing — L7-A is shipped
- **Blocks**: L7-D (proxy needs both endpoints + JWKS)

---

#### L7-C summary checklist — Network plumbing (server `v2.4.0`, ~3-4 days)

- [x] **C-1**: `FzWall.CLI.Helpers.Tproxy.install_l7_chain/0` + `remove_l7_chain/0` — idempotent `l7_prerouting` chain hooked at `prerouting / priority mangle` with a single TPROXY rule matching `wg-nexguard` ingress for `10.99.0.0/16` on TCP 80/443
- [x] **C-2**: `FzWall.Server` subscribes to `nexguard:l7:settings` and installs/removes the chain on `{:l7_enabled_changed, bool}`. Boot also calls `OrgSettings.l7_enabled?/0` and reinstalls if the toggle is already on
- [x] **C-3**: `FzWall.CLI.Helpers.Tproxy.install_fwmark_route/0` adds `ip route add local 0.0.0.0/0 dev lo table 100` + `ip rule add fwmark 0x1 lookup 100` at every fz_wall boot (zero-cost when no marks flow)
- [x] **C-4**: Opt-in `docker-compose.coredns.yml` overlay adds CoreDNS 1.11 with shared bind mount; activated via `docker compose -f docker-compose.prod.yml -f docker-compose.coredns.yml up -d`
- [x] **C-5**: `FzHttp.L7.CoreDnsHosts` GenServer writes `/etc/nexguard/internal-hosts` atomically (tmp + rename) from `Applications.list_enabled_for_bundle/0`
- [x] **C-6**: `coredns/Corefile` uses `hosts` plugin with `reload 1s` + 30 s TTL + fallthrough to 1.1.1.1 + 8.8.8.8
- [x] **C-7**: `CoreDnsHosts` subscribes to `nexguard:l7:apps`; regenerates the file on every `:apps_changed`
- [ ] **C-8**: VIP routing verification — packet to 10.99.0.x correctly steered to `:8443`. **DEFERRED** to L7-D where there's a real listener; v2.4.0 verifies only that the chain + rules exist (runbook step)
- [ ] **C-9**: Integration test using `nft list ruleset` + actual TCP connection to a mock VIP. **DEFERRED** to L7-D for the same reason — needs a real listener
- [x] **C-10**: Runbook `docs/migrations/v2.4.0.md` — kernel ≥ 5.6.9 pre-flight, port 53 / systemd-resolved collision, IPv4-only caveat, verify TPROXY plumbing, kill-switch behavior, full rollback recipe
- [x] **C-11**: Dockerfile `ARG VERSION` `2.3.0` → `2.4.0`, CHANGELOG `[2.4.0]` entry, NEXGUARD_LOGIC.md already documents the PubSub + endpoint contract from L7-B. **Tag + push deferred** to manual user step

---

#### L7-D summary checklist — L7 Proxy Go binary (server `v3.0.0`, ~7-10 days, biggest)

- [x] **D-1**: Go module `github.com/0xphuong/NexGuard/proxy` at subdirectory `proxy/` (chốt: cùng repo NexGuard). Layout: `cmd/nexguard-proxy/main.go` + `internal/{bundle,identity,logging}/`
- [x] **D-2**: `proxy/internal/listener` opens a `net.ListenConfig{Control: setTransparent}` TCP listener with `IP_TRANSPARENT` set on the fd. Build-tag split: `transparent_linux.go` runs the real syscall; `transparent_other.go` errors at listen time so macOS/Windows dev builds compile but operators can't deploy off-Linux. TPROXY model (not REDIRECT) means `conn.LocalAddr()` returns the original VIP — no `SO_ORIGINAL_DST` getsockopt needed
- [x] **D-3**: `listener.Listen/2` wraps the transparent TCP listener with `tls.NewListener` using `tls.Config{MinVersion: TLS13, GetCertificate: certHolder.GetCertificate}`. `proxy/internal/cert` builds an immutable `Store` from the bundle's apps (skips passthrough + cert-pending apps; fails closed on unparseable PEM); `cert.Holder` is the atomic.Pointer slot the bundle poller swaps on every pivot
- [x] **D-4 (partial)**: Identity client `internal/identity/{client,types}.go` — TTL cache (30 s default), `If-None-Match` + 304 path, 404 → `ErrUnknownVPNIP` + cache invalidation, `Invalidate/InvalidateAll`. PubSub-driven invalidation via Phoenix Channel/SSE pending (later commit)
- [x] **D-5 (partial)**: Bundle client `internal/bundle/{client,types}.go` — `Fetch` issues conditional GET (`If-None-Match` + `?since=N`), 304 path keeps current, 200 path atomic-swaps via `atomic.Pointer[Bundle]`. PubSub-driven refresh (`{:bundle_updated, v}` event) pending
- [x] **D-6**: `proxy/internal/policy.userInAnyAllowedGroup/4` resolves `app.allowed_group_ids` via `Bundle.FindGroup(gid).UserIDs.IsMember(userID)` — no second round-trip. Stale-bundle references (deleted group still in `allowed_group_ids`) are skipped, not crashed
- [x] **D-7**: `proxy/internal/policy.Decide/4` — break-glass (`access_scope=all`) → app-wide group gate → first-match-wins rule eval (`method` / `path_prefix` / `require_groups` / `require_mfa_age_seconds`) → default deny. Unknown rule action fails closed. `Decision{Allow, Reason, MatchedRule}` carries audit context
- [x] **D-8**: JWT signing landed end-to-end. **Server**: `FzHttp.L7.JwtSigner.active_signing_material/0` exposes the active key's `{kid, private_pem, algorithm}`; `BundleBuilder` now embeds `signing_key` in `/internal/bundle.json` (gated `:api_internal`). **Proxy**: `internal/jwt/signer.go` (stdlib `crypto/rsa` — no third-party JWT dep) parses PKCS#1 or PKCS#8 RSA PEM, signs claims `{user_id, email, groups, mfa_age_seconds, iat, exp}` with RS256 + `kid` header. `SignerHolder` atomic slot swap on every bundle pivot so the request hot path reads without a lock
- [x] **D-9**: `proxy/internal/handler.injectIdentityHeaders/2` sets `X-NexGuard-{User-Id,User-Email,User-Role,Groups,MFA-Age-Seconds,Identity-Jwt}` + applies per-app `inject_headers`. `stripSpoofedHeaders/1` removes any client-supplied `X-NexGuard-*` (case-insensitive — Go canonicalizes `NexGuard` → `Nexguard`) BEFORE we set our own. Per-app `strip_headers` also applied
- [x] **D-10**: `httputil.NewSingleHostReverseProxy(app.Backend)` per request — HTTP/1.1 + HTTP/2 + keep-alive inherited from net/http. Custom `ErrorHandler` returns the same deny page (502 `backend-error`) so backend failures don't bleed connection-reset to clients
- [x] **D-11**: `proxy/internal/handler/deny.go` renders a self-contained HTML page (inline CSS, no JS, no external assets) with title + code + reason + hostname. Defensive `html.EscapeString` on reason and hostname even though both are internal enums today
- [x] **D-12**: Unknown VIP → `http.StatusNotFound` + `X-NexGuard-Reason: unknown-app` + deny page. Unknown VPN-IP (identity 404) → 401 + `unknown-vpn-ip`. Policy denial → 403 + `denied`. Bundle not yet loaded → 503 + `no-bundle`. Backend failure → 502 + `backend-error`
- [x] **D-13**: `proxy/internal/handler.proxy.ServeHTTP/2` builds an `observation` struct each stage updates, then a deferred `slog.Info("request", ...)` emits ts / decision / reason / app_id / user_id / vip / status / bytes_out / latency / method / path / ua / client. JSON output via `slog.NewJSONHandler` (default in `internal/logging`)
- [x] **D-14**: `proxy/internal/observability/metrics.go` registers `nexguard_proxy_{requests_total{decision,status_family},request_duration_seconds{decision},bundle_version,bundle_age_seconds,identity_cache_size}` on a fresh `prometheus.Registry`. `RecordRequest` is nil-safe so handler tests don't need a metrics mock. Exposed at `/metrics` on the second port (`NEXGUARD_PROXY_OBS_LISTEN`, default `127.0.0.1:9090`)
- [x] **D-15**: `proxy/internal/observability/health.go` — `/healthz` always 200; `/readyz` returns 503 until `health.SetReady(true)` (called by `bootstrapBundle` after first signer + cert load). Health toggles back to 503 on signal-triggered graceful shutdown so an upstream LB drains traffic before the process exits
- [x] **D-16**: `proxy/Dockerfile` — 2-stage build (`golang:1.23-bookworm` → `gcr.io/distroless/static-debian12:nonroot`, ~20 MB final, static CGO_ENABLED=0 binary with `-trimpath -ldflags '-s -w'`). New `docker-compose.proxy.yml` opt-in overlay (mirrors the CoreDNS pattern) requires `network_mode: host` + `cap_add: NET_ADMIN` for the IP_TRANSPARENT setsockopt. New `--health-probe` subcommand on the binary itself hits `/readyz` on the obs port and exits 0/1 — distroless doesn't ship curl/wget so the Docker HEALTHCHECK calls back into the binary
- [x] **D-17 (partial)**: Unit tests landed for bundle client (200/304/503 paths + `FindAppByVIP`/`FindGroup`) and identity client (first fetch + cache hit, 404 → `ErrUnknownVPNIP` + cache clear, 304 TTL refresh, `Invalidate`, `HasAnyGroup`). Rule-eval tests pending the eval module
- [x] **D-18**: `proxy/internal/integration/proxy_test.go` — full pipeline test: mock NexGuard server emits a real bundle (with freshly-minted RSA signing key) + identity payload; mock backend echoes the injected headers; the proxy handler composes against both. Happy-path test verifies the JWT signature against the matching public key extracted from the test fixture's keypair. Deny path asserts the backend was never hit. Identity-cache burst verifies 20 follow-up requests after a warmup hit zero additional server calls
- [x] **D-19**: `TestPerf_ThroughputLatency` (gated by `NEXGUARD_PERF=1` env so normal `go test` doesn't run a 10 s loadgen). Measured on macOS arm64: **1143 rps sustained over 10 s, p50=8 ms, p99=21 ms** — both budgets in task.md (≥ 1000 rps, p99 ≤ 50 ms) met. Some error rate is expected because `http.DefaultClient` doesn't reuse connections under this loadgen pattern; the proxy itself is not the bottleneck
- [x] **D-20**: Independent security review of `proxy/` surfaced 2 critical, 4 high, 5 medium, 3 low findings. All Critical (C1 inject/strip overrides identity; C2 sub-2048-bit RSA keys accepted) + High (H1 plain HTTP bundle fetch; H2 outbound TLS unpinned + backend can spoof response identity headers; H3 SSRF via backend scheme; H4 stale identity cache across pivots) fixed inline this release. M1/M2/M3/M5 + L1-L3 documented in CHANGELOG, tracked for v3.0.1
- [x] **D-21**: Dockerfile `ARG VERSION` 2.4.0 → 3.0.0. CHANGELOG `[3.0.0]` entry covering the proxy daemon + mTLS internal control plane + security fixes. `docs/migrations/v3.0.0.md` runbook walks cert provisioning, Caddy verification, proxy overlay activation, kill-switch, cert rotation, and three rollback paths. Tag + push deferred to manual user step

---

#### L7-E summary checklist — Operations (server `v3.0.1`+, ~2-3 days)

- [x] **E-1**: Bundle atomic swap (`atomic.Pointer[Bundle]` in `proxy/internal/bundle/`) + LKG ring (last 3 versions kept in the Phoenix ETS table `:l7_bundle`) — shipped in L7-D (v3.0.0)
- [ ] **E-2**: Audit log integration — proxy POSTs each `allow` / `deny` to a Phoenix audit endpoint (batched + sampled). **Highest remaining ops value** — current proxy logs decisions to stderr only; no per-request entry survives in the audit DB
- [x] **E-3 (partial)**: Deny page redesigned (commit `4ac7539`) — modern, dark-mode, per-status messaging, request ID display, CSP-tight. Per-org branding (logo / accent / custom copy from `/settings/customization`) still pending
- [ ] **E-4**: JWT signing key rotation UI button at `/settings/security` — currently `JwtSigner.rotate/3` exists but only callable via `iex` or mix task. Add LiveView affordance + audit (`l7.signing_key.rotate` action already whitelisted)
- [x] **E-5 (partial)**: Kill switch via `:l7_enabled_changed` PubSub flips the nftables TPROXY chain + the proxy refuses connections. Graceful drain of in-flight connections on shutdown still on the wishlist
- [ ] **E-6**: Tests + docs — base coverage shipped per-phase; integration test for full kill-switch round-trip (Phoenix flip → fz_wall chain remove → proxy drain) still pending

---

#### Polish backlog — Applications module review (2026-06-24)

Findings from the post-v3.0.2 module review. PR #1 ($1+#7+#2 — enable-bypass + permitted-list refactor + audit diff) shipped commit `c9d60e0`. Remaining items grouped by theme:

##### R — Applications correctness / UX (~2-3h total)

- [ ] **R3**: L7 rules editor races on concurrent admin edits — `show_live.ex:131-165` reads `socket.assigns.application.l7_rules` then writes the new list back via `update_application`. Two admins on the same app overwrite each other's rules. Fix: move add/delete/reorder into `Applications.L7Rules` (or just `Applications`), each wrapping a `Repo.transaction` that re-reads `l7_rules` inside the txn before append/reorder. ~1-2h
- [ ] **R4**: X509 parser duplicated in `applications_live/form_component.ex:94-157` (`preview_cert/1`) — same job as `FzHttp.L7.CertParser` shipped in Phase A of ADR-015. Expose `CertParser.parse_cert_only/1` (skip key match) and replace the inline parser. ~30min
- [x] **R5**: ~~Index page stats strip step_ca tile~~ — addressed adjacent in v3.0.9: the **form modal** demotes step_ca behind a "Pending" badge (`ng-radio-card--disabled`). Index stats strip step_ca tile only renders when count > 0, so it self-hides for library-first deployments. Full split into library/upload/step_ca tiles not done; revisit if a deployment ends up with mixed sources
- [ ] **R6**: `applications_live/{index,show}` LiveViews don't `Applications.subscribe()` — multi-admin scenarios show stale state until refresh. Add `if connected?(socket), do: Applications.subscribe()` + `handle_info(:apps_changed, ...)` reload. Same pattern in the new `setting_live/certificates_live.ex` for cert-library mutations. ~30min

##### V — Versioning + release housekeeping (~30min)

- [x] **V1**: Bump `Dockerfile.prod ARG VERSION` to current. Shipped — bumped through v3.0.4 → v3.0.5 → v3.0.6 → v3.0.7 → v3.0.8 → v3.0.9 with matching CHANGELOG entries + tags. v3.0.2's specific `docs/migrations/v3.0.2.md` deploy doc still missing (cert library steps were folded into the v3.0.5 runbook instead — close enough not to backfill)
- [ ] **V2**: Migrate existing apps with `cert_source: :upload` → `:library` — for orgs that already have a wildcard cert covering the hostnames, set `tls_auto_match: true` and clear the per-app PEM. Helper mix task or one-shot SQL

##### X — External (out-of-repo, DNS team coordination)

- [ ] **X1**: bind9 RRL — add `10.0.235.3` (NexGuard gateway IP) to `exempt-clients`. NexGuard side already self-shapes via `max_concurrent 100` + serve_stale + prefetch; RRL on bind9 was the amplifier in the 2k-req/s peak we hit during prod smoke. 5min DNS-team task
- [ ] **X2**: bind9 capacity — raise `recursive-clients 1000 → 4000`, enable `prefetch 2 9;` + `stale-answer-enable yes;`, bump `max-cache-size 256m → 512m`. Recommended once VPN client count grows past ~10

##### O — Observability nice-to-have (~1-2h each)

- [ ] **O1**: Add `prometheus :9153` to `coredns/Corefile` + scrape config. Gives cache hit rate, forward latency, SERVFAIL count — confirms the 85-90% cache-hit assumption from the design
- [ ] **O2**: Grafana dashboard template for CoreDNS + L7 proxy metrics — drop-in JSON in `docs/dashboards/`
- [ ] **O3**: Post-mortem doc — `docs/post-mortem/v3.0.0-launch.md` captures the DNS forward bug, `fallthrough .` syntax, env-line discipline, audit whitelist gap, microsecond-precision pitfall, modal stateful-root requirement. Learnings durable across the team

##### D — Admin dashboard (`/dashboard`)

`/dashboard` redesign tracked across three phases, applying the
`frontend-design-direction` skill — dashboard answers "is the system
healthy right now?" in <2 seconds, NOT a navigation hub (sidebar
serves that).

- [x] **D-Phase-A** (shipped `v3.0.6`, commit `9083f83`): Hero status banner + 4 domain stat tiles (Identity / Network / L7 ZTNA / Activity) + recent activity feed. 11 conditional hero alerts. Removed Quick Actions duplicate of sidebar. Per-card random color scheme dropped — state-driven colour only
- [x] **D-Phase-B** (shipped `v3.0.7`, commit `c11d718`): Security compliance scorecard (7 always-visible checks) + Live VPN sessions panel (top 8 devices handshook in last 3 minutes)
- [ ] **D-Phase-C**: Historical trend visualisations — 2-4 chart panels below the current zones. Scope split by data availability:
  - [ ] **D-C1** (~3-4h, no deps): Connection sparkline (24h active VPN sessions, hourly buckets) + Audit events timeline (7-day daily buckets). Inline SVG sparkline — no chart library dep. Data sources already exist (`Device.latest_handshake`, `AuditLogs.list_logs`)
  - [ ] **D-C2** (~6h, blocked by **E**): L7 access pulse (allow/deny ratio + top denied apps) + Top apps by traffic. Requires proxy → audit DB pipeline (task E below) to land first so the data is queryable from Phoenix
- [ ] **D-Phase-D** (nice-to-have, no schedule): Realtime via PubSub — dashboard subscribes to `nexguard:l7:apps`, `nexguard:health`, `nexguard:audit` (new) so admin doesn't refresh page to see new events. Replaces the current mount-once snapshot pattern

Phase A+B are stable and live on prod. Phase C-1 ship-able today;
Phase C-2 deferred until task E (next section) lands. Phase D
purely UX nicety — defer until there's a real need.

---

#### L7-F summary checklist — Internal CA, conditional (server `v3.1.0`, ~3-4 days)

- [ ] **F-1**: smallstep `step-ca` Docker container added (only when any app has `cert_source: step_ca`)
- [ ] **F-2**: Root CA + intermediate CA generation script
- [ ] **F-3**: ACME provisioner config
- [ ] **F-4**: Phoenix-side cert request when admin sets `cert_source: step_ca` → step-ca issues leaf, stored in `applications.cert_pem`
- [ ] **F-5**: 90-day rotation cron — Oban job re-issues 30 days before expiry
- [ ] **F-6**: Tests + runbook + root key backup procedure

---

#### L7-G summary checklist — Client CA provisioning, conditional (client `v0.1.0`, ~1-2 days)

- [ ] **G-1**: NexGuard Connect downloads CA root via `Security.framework` (macOS) — uses internal API `/.well-known/nexguard-ca.pem`
- [ ] **G-2**: Install in System keychain (per-user trust to avoid root prompt)
- [ ] **G-3**: Admin banner on success / failure
- [ ] **G-4**: MDM `.mobileconfig` payload template for enterprise distribution
- [ ] **G-5**: Trigger only when active server has at least one `cert_source: step_ca` app
- [ ] **G-6**: Tests + docs

---

#### L7-A detailed checklist — DB schema + admin UI (server `v2.2.0`, ~5-7 days)

**Scope reminder**: Pure Phoenix/Ecto work. No proxy / CoreDNS / step-ca deployment yet — L7-A is data + admin tooling only. Enforcement starts at L7-D.

##### Phase 1 — Database schema (~1 day)

- [x] **M-1**: migration `20260620000001_create_access_groups` — `id (UUID PK)`, `name (unique)`, `description`, `source`, `external_id`, timestamps + indexes
- [x] **M-2**: migration `20260620000002_create_user_group_memberships` — composite PK `(user_id, group_id)`, FK cascade, `source`, `added_by_id (FK users nilify)`, `inserted_at`
- [x] **M-3**: migration `20260620000003_create_applications` — NEW table (was "extend" — `applications` didn't exist yet); `hostname (unique)`, `virtual_ip inet (unique)`, `backend`, `cert_source`, `cert_pem text`, `key_pem binary` (app-encrypted), `tls_mode default 'terminate'`, `l7_rules jsonb '[]'`, `enabled boolean false`
- [x] **M-4**: migration `20260620000004_create_application_allowed_groups` — composite PK `(application_id, group_id)`, FK cascade
- [x] **M-5**: migration `20260620000005_add_access_scope_to_users` — `access_scope` default `'limited'` + partial index on `'all'`
- [x] **M-6**: migration `20260620000006_create_org_settings` — single-row pattern (id=1, CHECK constraint) + seed insert; `l7_enabled boolean default false`
- [ ] Verify: `docker compose up -d` → migrations auto-run; `docker compose exec app mix ecto.rollback --to 20260612000001` reverses; `\d access_groups` etc. confirm schema

##### Phase 2 — Schemas + contexts + tests (~2 days)

- [x] **S-1**: `FzHttp.AccessGroups.Group` schema + `Group.Changeset` (create / update / idp_sync)
- [x] **S-2**: `FzHttp.AccessGroups.Membership` schema + `Membership.Changeset` (composite PK via per-field flags)
- [x] **S-3**: `FzHttp.Applications.Application` schema (NEW) + `Application.Changeset` (hostname RFC 1035, VIP in 10.99.0.0/16, cert SAN match via `:x509`, L7 rules JSON validation, immutable VIP on update) + `Applications.AllowedGroup` join schema
- [x] **S-4**: extend `FzHttp.Users.User` — added `access_scope`, `group_memberships`, `groups (many_to_many)`
- [x] **S-5**: `FzHttp.OrgSettings.Settings` schema (singleton, integer id=1) + `Settings.Changeset`
- [x] **C-1**: `FzHttp.AccessGroups` context — `list_groups`, `fetch_group_by_id`, `get_group_by_name`, `list_groups_with_members` (bundle), `list_groups_for_user` (identity API), `create_group`, `update_group`, `delete_group`, `add_member`, `remove_member`; full audit on every mutation
- [x] **C-2**: `FzHttp.Applications` context — `list_applications`, `fetch_application_by_id`, `list_enabled_for_bundle`, `create_application` (allocates VIP inside transaction), `update_application`, `set_application_enabled`, `delete_application`, `add_allowed_group`, `remove_allowed_group`; PubSub `nexguard:l7:apps` broadcast on every mutation
- [x] **C-3**: `FzHttp.OrgSettings` context — `get/0`, `l7_enabled?/0`, `set_l7_enabled/3`; PubSub `nexguard:l7:settings` broadcast on toggle; no-op detection skips audit + broadcast on identical write
- [x] **C-4**: `FzHttp.L7.VipAllocator` — advisory-lock-based first-free scan over 10.99.0.1 → 10.99.255.254 (skip network + broadcast); `allocate/0` opens own transaction, `allocate_inside_transaction/0` joins caller's transaction so VIP-pick + INSERT share the lock
- [x] **A-1**: `FzHttp.AccessGroups.Authorizer` — `view_access_groups`, `manage_access_groups` (admin only); unprivileged see nothing
- [x] **A-2**: `FzHttp.Applications.Authorizer` (NEW since table didn't exist) — `view_applications`, `manage_applications`, `manage_l7_policy`
- [x] **A-3**: `FzHttp.OrgSettings.Authorizer` — `view_org_settings`, `manage_l7_settings`
- [x] **T-1**: `test/fz_http/access_groups_test.exs` — 167 LOC, 17 tests across list/create/update/delete/add_member/remove_member/list_groups_for_user + permission denial cases
- [x] **T-2**: `test/fz_http/applications_test.exs` — 260 LOC, covers VIP allocation, hostname normalisation, cert_source upload-requires-cert, duplicate hostname, passthrough rejected v1, l7_rules schema validation, enable gating, bundle reader, allowed_group round-trip, cascade delete
- [x] **T-3**: `test/fz_http/l7/vip_allocator_test.exs` — 77 LOC, async:false, exercises first-free pick, skipping used VIPs, concurrent allocations via `Task.async` (advisory lock prevents collision)
- [x] **T-4**: `test/fz_http/org_settings_test.exs` — 82 LOC, async:false, get/toggle/permission/PubSub broadcast/no-op suppression
- Test fixtures: `test/support/fixtures/access_groups_fixtures.ex` + `applications_fixtures.ex` for other suites to reuse

##### Phase 3 — Admin UI LiveView (~3 days)

- [x] **R-1**: routes — `/access-groups`, `/access-groups/new`, `/access-groups/:id` (settings/l7 deferred to Wave 4)
- [x] **R-2**: nav — "Access Groups" entry in `sidebar_component.ex` under Configuration
- [x] **U-1**: `AccessGroupsLive.Index` (`index_live.ex` + `index.html.heex`) — table with name, source badge, member count, created timestamp, delete action; "New Group" patches to modal
- [x] **U-2**: `AccessGroupsLive.FormComponent` (modal) — name + description + phx-change live validation
- [x] **U-3**: `AccessGroupsLive.Show` — inline edit name/desc, member roster (table) with add-by-email + remove, danger zone delete
- [x] **U-4**: Empty state on Index — "No groups yet — create one to start gating apps"
- [x] **U-5**: Delete confirm — `data-confirm` warns about member + app reference cascade
- [x] **U-6**: extend `UserLive.Show` — "Group Memberships" card; add-by-dropdown form, table with remove, navigates to group detail on name click
- [x] **U-7**: extend `UserLive.Show` — "L7 Access Scope" card with badge (`limited`/`all`); single-button toggle with `data-confirm` break-glass warning; `Users.set_access_scope/4` audited
- [ ] **U-8**: `ApplicationsLive.Index` partial (Wave 3a — list + stats strip + delete-with-modal; **New button disabled, form ships Wave 3b**). Routes: `/applications`. Nav: "Applications" under Configuration.
- [x] **U-8 (form basic)**: Wave 3b-1 ships `ApplicationsLive.FormComponent` (create + edit) + `ApplicationsLive.Show` MVP. Routes `/applications/new` + `/applications/:id` + `/applications/:id/edit`. Cert source picker as card-style radios (step_ca path active; upload card disabled with "Wave 3b-2" badge). VIP shown read-only on Edit.
- [x] **U-9**: Hostname field RFC 1035 validation (live via `phx-change` already wired through changeset)
- [x] **U-10**: Backend URL validation (http/https prefix, length)
- [x] **U-11**: Cert source picker — card-style radios, step_ca active
- [x] **U-12**: Cert upload form — `cert_pem` + `key_pem` textareas (mono font, phx_debounce 500); inline cert preview block showing parsed Subject + SANs + expiry once the PEM parses (degrades gracefully if invalid); appears only when `cert_source = upload` is selected; existing changeset already enforces SAN matches hostname
- [x] **U-13**: Required groups picker on `ApplicationsLive.Show` — dropdown of unlinked groups + add; table of allowed groups + remove via styled modal; empty-state hint flags zero-group apps deny everyone (security signal)
- [x] **U-15**: TLS mode hidden as `terminate` (passthrough deferred to v2 by changeset)
- [x] **U-16**: Enable toggle gated — uses `set_application_enabled` which fails if no L7 rules; surfaced as flash error
- [ ] **U-9**: hostname field + RFC 1035 validation indicator
- [ ] **U-10**: backend URL field + validation
- [ ] **U-11**: cert source picker — radio "Upload" vs "Use NexGuard internal CA"
- [ ] **U-12**: cert upload form — textareas for `cert.pem` + `key.pem`; client-side preview cert subject + expiry
- [ ] **U-13**: required groups multi-select
- [x] **U-14**: L7 rules row editor on `ApplicationsLive.Show` — add-form (action radios, method pill checkboxes for GET/POST/PUT/DELETE/PATCH, path_prefix, require_groups pulled from app's allowed_groups, require_mfa_age_seconds), table with up/down arrows + delete per row, implicit default-deny row pinned at the bottom for clarity
- [ ] **U-15**: TLS mode dropdown — 'terminate' default; 'passthrough' disabled with tooltip "Available in v2"
- [ ] **U-16**: enabled toggle — disabled until cert + hostname + ≥1 rule present
- [x] **U-17**: `SettingLive.L7` — `/settings/l7` route + sidebar entry under Settings; renders status badge + master toggle card
- [x] **U-18**: Pre-toggle confirmation modal — distinct enable / disable copy each spelling out the concrete consequences (TPROXY chain, CoreDNS overrides, bundle reload, per-app preserve-on-disable) plus a link to SPEC §8
- [x] **U-19**: Post-enable status banner — green card listing "X enabled apps", VIP subnet `10.99.0.0/16`, TPROXY port `:8443`. Special hint when zero apps enabled (proxy idle) with link to declare one
- [x] **T-5**: `test/fz_http_web/live/access_groups_live/index_live_test.exs` — empty state, stats strip + row, unprivileged blocked, create-via-modal, duplicate-name validation, delete removes row
- [x] **T-6**: `test/fz_http_web/live/applications_live/live_test.exs` — Index empty + populated, create via step_ca path, hostname validation, allowed-group picker, L7 rule add, implicit-deny row always rendered
- [x] **T-7**: `test/fz_http_web/live/setting_live/l7_live_test.exs` — DISABLED default, unprivileged blocked, enable + disable via modal flips state + broadcasts PubSub `{:l7_enabled_changed, ...}`
- [x] **T-8**: `test/fz_http_web/live/user_live/l7_show_test.exs` — Group Memberships add + remove via styled modal; Access Scope default `:limited`, flip-to-`:all` modal warning + badge update

##### Phase 4 — Polish + docs (~0.5 day)

- [x] **P-1**: `NEXGUARD_LOGIC.md` §17 — L7 tables + contexts + authorizers + admin routes + two-level opt-in + routing preview
- [x] **P-2**: `docs/migrations/v2.2.0.md` — preflight, apply, verify (links the `verify_l7a_schema.sql` script), rollback, operational impact
- [x] **P-3**: `CHANGELOG.md` `[2.2.0] - 2026-06-21` — full L7-A description (data model + contexts + UI + tests + new x509 dep + dormant-on-deploy note)
- [x] **P-4**: Obsidian `Roadmap.md` — added 2.2.0 to Released table + marked L7-A shipped in the L7 ZTNA section; `00-Index.md` Latest release bumped
- [x] **P-5**: Tag `v2.2.0` pushed (commit `245ef73`); `nexguard-releases/versions.json` bumped to `latest: 2.2.0`, server CHANGELOG mirrored, README updated, download_url retargeted to `v2.2.0` tag

##### Acceptance criteria

Admin can end-to-end:
- [ ] Create group "engineering" via `/admin/access-groups`
- [ ] Assign user to group + set `access_scope` in user edit page
- [ ] Declare app via `/admin/applications/new`: hostname, backend, cert upload, required groups, L7 rules, enabled
- [ ] Toggle org-level L7 on via `/admin/settings/l7` → banner shows "X apps active"
- [ ] **No proxy / CoreDNS / step-ca process running** — L7-A delivers data + UI only; enforcement comes in L7-D
- [ ] DB consistency: deleted group warns about reference apps; cascade rules work

##### Dependencies

- **Blocked by**: nothing — start anytime
- **Blocks**: L7-B (Identity API + bundle compile need these schemas)

---

### 🟢 Quick wins (low effort, complete existing features)

| ID | Task | Effort | Notes |
|---|---|---|---|
| S1 | **Pending device — email / webhook notification to admin** | ~1.5-2h | Extend the in-portal notification (shipped in 2.1.1) out-of-portal: email admin list / POST to per-org Slack or Discord webhook when a device lands in `pending`. Phase 2 after the in-portal badge. Useful for teams ≥10 users where admins don't sit in the portal all day. |
| S2 | **Audit log enrichment — `policy_bypass` flag** | ~15min | Log a `metadata->>'policy_bypass'` flag when an unprivileged user self-enrolls via NexGuard Connect's native API while `allow_unprivileged_device_management` is OFF in admin config. Free security observability for compliance auditors. Document the known bypass: the portal toggle only restricts UI, not the native API. Approval gate still applies, but the bypass is now visible in audit. |
| S3 | **Clarify tooltip** on "Allow Unprivileged Device Management" toggle | ~10min | Add note: "NexGuard Connect clients can still self-enroll into `Pending` state and require admin approval." Prevents the admin-confusion case ("toggle is off but users still enrolling?"). Pairs with S2. |
| S4 | **Disable user device from portal** (suspend without deleting) | ~2-3h | Keep device row + audit history but block VPN access. Currently admin can `revoke_approval` → device drops to `pending` and tunnel disconnects — covers the "stop access" use case, but doesn't communicate "intentionally suspended" to the user. A new `status: "suspended"` would. |
| S13 | **`enroll_device` no-op path: skip audit + notifications when nothing changed** | ~30 min | Linux CLI calls `POST /api/v1/devices/enroll` on **every Connect** as its idempotent config-fetch mechanism (elegant on the client side, but noisy server-side). Server-side dedup by `(user_id, name)` already returns the existing row without a DB write when the public_key hasn't changed (`devices.ex` line 514 `%Device{public_key: ^public_key} = device -> {:ok, device}`), but the controller still fires `AuditLogs.log("device.create", ...)` outside the case block, and any downstream PubSub / admin notification chain runs regardless. Fix: emit audit + notifications ONLY in the "created" / "public_key updated" branches; the pure no-op branch stays silent. Reduces steady-state audit rows by roughly `num_linux_clients × connects_per_day` (currently ~50/day for our internal team, would grow with rollout). |

### 🟡 Medium effort, valuable

| ID | Task | Effort | Notes |
|---|---|---|---|
| S5 | **Admin "Force re-auth" policy** (org-level setting "user must sign in again after X days") | ~2h server + ~1h client | Extra session control beyond the 24h VPN session. Per-org configurable. Server stamps `last_signed_in_at`; client checks on every refresh. |
| ~~S6~~ | ~~**Bulk device approve/revoke**~~ | done | Shipped in **v3.0.8** as part of the devices redesign — bulk Approve / Revoke / Delete with confirm modal + sticky toolbar |
| ~~S7~~ | ~~**Audit log search + filter UI**~~ | done | Shipped in **v3.0.9** — free-text search across actor_email / target_label / target_id / IP, time-range chip (24h/7d/30d/90d), Reset button, empty-state variants. CSV export + PubSub live tailing + severity tag classifier deferred to Pass 2 |
| S8 | **API documentation** (OpenAPI / Swagger for `/api/v0/`) | ~2-3h | Enable third-party integration. Auto-generated from controller annotations would be lowest-maintenance. |

### 🔵 Larger features

| ID | Task | Effort | Notes |
|---|---|---|---|
| S9 | **Compliance pre-flight** (FileVault / OS version / firewall check before connect) | ~3h server + ~3h client | Enterprise requirement. Server-side policy schema ("require macOS >= 14, FileVault on") + client-side check + report on Connect. |
| S10 | **Custom branding from server** (logo + accent color per org) | ~3h + server config endpoint | Per-org identity if NexGuard ever sells as SaaS. Client fetches `GET /config/branding` on bootstrap, caches locally. |
| S11 | **MDM profile support** (`.mobileconfig` template + docs) | ~3-4h client + server docs | Corporate distribution via Jamf / Intune. Allows IT to push server URL + restrictions automatically. |
| S12 | **Webhook system** for org events (device pending, user signed in, MFA challenge, approval changes) | ~3-4h | External integration target. Per-org webhook URL + event filter + retry/backoff. Generalizes S1. |
| S14 | **v4.0.0 -- retire legacy `/rules`** | ~1-2h | Drop the `/rules` UI (route + sidebar), remove `Rules.as_settings/0` call from `FzHttp.Events.set_rules/0` + `FzHttp.Server.load_settings`, drop the `rules` table via Ecto migration. **No auto-migration into policies** -- admin must recreate any remaining legacy rows as policies BEFORE upgrading. Operator decision (2026-07-27): current fleet has <10 legacy rows, so admin-time migration is cheaper than maintaining a translation migration. Pre-flight check on boot: if `SELECT count(*) FROM rules > 0` when the migration runs, log a loud warning + refuse to drop the table until the admin manually clears it or overrides via `NEXGUARD_ALLOW_LEGACY_RULES_LOSS=true`. Ship as **v4.0.0** (major bump for schema drop). |

---

## 🎯 Recommendation order

### Path A — close the device approval loop (continuity from 2.1.x)

Ship as **v2.2.0**:
1. **S1** email/webhook notification to admin (most user-visible)
2. **S2** audit `policy_bypass` flag
3. **S3** tooltip clarification

These three together complete the device-approval workflow story shipped in 2.1.0 + 2.1.1.

### Path B — admin productivity

Ship as **v2.2.0**:
1. **S6** bulk approve/revoke
2. **S7** audit log search + filter UI
3. **S4** suspend (status: suspended)

Pivot away from approval-workflow polish toward general admin ergonomics.

### Path C — enterprise session policy

Ship across server + client:
1. **S5** force re-auth policy (server side)
2. **S9** compliance pre-flight (server policy + client check)

Both need coordinated client work — bigger scope but enables enterprise sales.

---

## ❌ Won't do — explicit decision

| Task | Why skipped |
|---|---|
| **Live config push via WebSocket** | Config changes are rare in self-hosted setups; client sign-out / sign-in is sufficient refresh. Adds significant complexity (channel lifecycle, auth, reconnect) for low payoff. Re-evaluate if multi-tenant SaaS happens. |
| **Persistent notifications** (survive app restart) | In-memory `GenServer` state is by design — notifications are transient signals, not a long-running log. Audit logs cover the durability need. |
| **Multi-org SaaS architecture** (single deployment serving many orgs) | NexGuard is positioned as self-hosted. Multi-tenancy at the client (per-server Keychain + org switcher) already covers the legitimate "user belongs to multiple orgs" case. Server-side multi-tenancy is a different product. |

---

## How to pick the next task

Same rule as the client: **pick by what's hurting**, not by a fixed order.

- If admins keep missing pending devices for hours/days → **S1** (email/webhook).
- If a compliance auditor asks "show me policy bypasses" → **S2 + S3**.
- If you're onboarding a team and clicking Approve 20 times in a row → **S6** (bulk).
- If a team member can't find an audit log entry → **S7** (search + filter).
- If an outside team asks for a programmatic integration → **S8** (OpenAPI).

When none of those hurt, the safe default is closing the device approval workflow loop (Path A above).
