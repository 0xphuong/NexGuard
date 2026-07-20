# Changelog

All notable changes to NexGuard will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

---

## [3.2.2] - 2026-07-20

Additive: native auth token responses now include an authoritative
`session_expires_at` timestamp. Native clients (v0.5.7+) use it to
detect session expiry locally, without needing a live server call --
critical when the tunnel is dead but the client still needs to sign
the user out cleanly (tunnel-DNS unreachable = any HTTP call to the
server URLErrors out, so the 401 that would normally trigger
forceReSignIn never surfaces).

### Added

#### `session_expires_at` field in `/api/v1/native/token` + `/api/v1/native/refresh` response

Response JSON now includes:

```json
{
  "access_token": "...",
  "refresh_token": "...",
  "token_type": "Bearer",
  "expires_in": 3600,
  "session_expires_at": "2026-07-21T05:00:16.497725Z",
  "user": { ... }
}
```

`session_expires_at` is the ISO 8601 UTC timestamp at which the VPN
session becomes invalid per the org-configured
`vpn_session_duration` policy. Computed as
`user.last_signed_in_at + vpn_session_duration`. `null` when the
org disabled session-based expiry (`vpn_sessions_expire? ==
false`) or when the user has never signed in (defensive; the endpoint
just issued a refresh so this shouldn't happen from here).

Native clients (macOS v0.5.7, Windows + Linux TBD) persist this in
their per-server secret store and schedule a local Task that fires
`forceReSignIn` at that exact moment -- no server round-trip needed
to detect session expiry. Bonus consequences:

- **Instant detection**: sign-in screen appears at the exact
  moment the server considers the session dead, not
  minutes-to-hours later.
- **Works when tunnel is dead**: client independently knows, so
  the "connected but tunnel doesn't pass traffic + no
  notification" hang is gone.
- **Backward compatible**: pre-3.2.2 servers don't emit the field;
  new clients decode-if-present and fall back to their v0.5.6
  detection paths (handshake-stale probe, refresh timer 401,
  explicit user reconnect).

Zero migration required. One-line schema change (JSON response
shape only; no DB migration).

---

## [3.2.1] - 2026-07-16

Observability polish. No schema change, no API change, no client
coordination -- pure Phoenix-side change; older clients unaffected.

### Fixed

#### `TLS handshake error from 127.0.0.1: EOF` noise in `nexguard-proxy` log

Every 60 s, `docker logs nexguard-proxy` emitted a line like:

    2026/07/16 14:14:57 http: TLS handshake error from 127.0.0.1:42588: EOF

Symptom benign but hid real errors + wasted log-rotation budget.

Root cause: `FzHttp.HealthMonitor.probe_proxy/0` opened a bare TCP
socket to the proxy's TLS transparent-proxy listener (`127.0.0.1:8443`),
proved `accept()` completed, then closed. Go's `net/http.Server`
stdlib logs a "TLS handshake error: EOF" every time an accepted
connection closes before ClientHello. The comment in the old
`probe_proxy/0` said "don't bother with TLS -- we'd need a client
cert", which is correct but sidesteps the log-noise cost.

Fix: probe `http://127.0.0.1:9090/readyz` on the proxy's plaintext
observability port instead. Same endpoint the proxy's own docker
`HEALTHCHECK --health-probe` uses. Implementation uses raw
`:gen_tcp` with `packet: :http_bin` so the Erlang inet driver
parses the status line -- no new dep, no `:inets`, no Finch pool
to babysit for a probe that fires every 60 s.

Bonus (accidental improvement in signal quality): `/readyz`
returns 503 during bundle-bootstrap and during SIGTERM drain --
the old TCP-connect probe reported `:ok` in both windows (listener
still bound). The topbar dot now correctly turns red for a proxy
that's stuck refreshing its policy bundle, matching what "healthy"
actually means to a client.

Rollback: single-file revert, no dependencies, no client
coordination.

---

## [3.2.0] - 2026-07-13

Additive telemetry release. One migration extends `devices` with
three nullable columns; no schema changes to existing columns, no
breaking API changes -- older Windows / macOS / Linux CLI clients
that don't send the new headers keep working unchanged (their rows
render `—` for the new fields until they hit any auth endpoint
after upgrading).

### Added

#### Host OS + CPU architecture telemetry on the `devices` table

Native clients already report `X-NexGuard-Client-Platform` +
`X-NexGuard-Client-Version` (identifying the client build family
+ its own version). This release adds three more headers that
identify the **host OS underneath**:

    X-NexGuard-Client-OS-Name       "macOS" | "Windows Server 2022 Datacenter" | "Ubuntu"
    X-NexGuard-Client-OS-Version    "14.3.1" | "10.0.20348" | "22.04.3 LTS"
    X-NexGuard-Client-Arch          "arm64" | "x86_64" | "aarch64"

Migration `20260714000001_add_client_os_to_devices.exs` adds three
nullable string columns (`client_os_name` / `client_os_version` /
`client_arch`, max 64/32/16 chars). Same best-effort ingestion
path as the existing headers: `Devices.record_client_info/2` (now
a map arg) casts + length-validates + stamps
`client_last_seen_at`; any DB failure is logged and swallowed so
telemetry can never break the enroll / config flow.

Admin UI:

- Devices index table gains a secondary line under the Client
  column showing `<os_name> <os_version> · <arch>`. The primary
  line still reads `<platform> · <client_version>`.
- Device details page gets two new rows in the Client card:
  **Operating System** (name + version) and **Architecture**
  (mono-formatted).

Rationale: support tickets like "app slow on MacBook Pro" become
diagnosable at a glance (arch = `x86_64` on Apple Silicon = Rosetta
runtime = suspected missing native arm64 build). Fleet audits like
"which orgs still have Windows Server 2019 boxes" become one
`WHERE client_os_name ILIKE '%Server 2019%'` query. No enforcement
gate -- passive telemetry only, same policy as `client_version`.

Native client work to actually populate the headers is separate
per-platform work in the [`nexguard-connect`](https://github.com/0xphuong/nexguard-connect)
repo (macOS: `ProcessInfo.operatingSystemVersionString` + `uname -m`;
Windows: `Get-CimInstance Win32_OperatingSystem` + `PROCESSOR_ARCHITECTURE`;
Linux: parse `/etc/os-release` + `std::env::consts::ARCH`). Server
accepts the fields whenever any client build starts sending them
-- no coordinated release required.

### Docs

- README gains a **NexGuard Connect (VPN client)** section with one-liner install
  commands for macOS / Linux (`curl … install.sh | bash`) and Windows PowerShell
  (`irm … install.ps1 | iex`). Scripts live in the
  [`nexguard-releases`](https://github.com/0xphuong/nexguard-releases) repo and
  auto-detect OS, verify SHA-256 against `versions.json`, and on macOS strip the
  Gatekeeper `com.apple.quarantine` attribute so the "Apple could not verify"
  prompt no longer fires.

---

## [3.1.0] - 2026-07-03

Two feature adds serving the native clients. No schema changes to
existing tables (one additive migration extends `devices`), no
breaking API changes -- older Windows / macOS clients continue to
work unchanged.

### Added

#### Client identity telemetry on the `devices` table

Every native-client request to `/api/v1/devices/enroll` and
`/api/v1/devices/me/config` now carries
`X-NexGuard-Client-Platform` + `X-NexGuard-Client-Version` headers
(set by NexGuard Connect Windows 0.1.8 and macOS 0.0.12). The
server stamps those into new columns on the `devices` row plus a
`client_last_seen_at` timestamp so admins can see which build each
device is running at a glance.

  * **Migration** `20260703000001_add_client_metadata_to_devices` --
    adds `client_platform` / `client_version` (nullable strings,
    max 32 chars) + `client_last_seen_at` (utc_datetime_usec) to
    `devices`. Nullable so devices predating the header rollout
    stay working -- they render a muted em-dash in the admin UI.
  * **`FzHttp.Devices.record_client_info/3`** -- best-effort
    passive-telemetry helper. Header values `""` or the literal
    `"unknown"` (native client couldn't read its own version)
    both collapse to `nil` so the DB never stores a misleading
    string. Errors are logged + swallowed; a telemetry write never
    breaks the enroll / config flow that actually matters.
  * **`FzHttpWeb.API.V1.DeviceController`** -- extracts the headers
    via `Plug.Conn.get_req_header/2` after each successful
    `enroll` / `me_config` and calls `record_client_info`. Values
    are truncated to 32 chars at the boundary in case a rogue proxy
    injects a huge string.
  * **Admin UI**:
    - Device list (`devices_table.html.heex`) grows a **Client**
      column between Connection and Tunnel IPs, formatted
      `platform · version` (e.g. `windows · 0.1.8`) or `—` when
      the device hasn't reported yet.
    - Device detail (`device_details.html.heex`) grows a **Client**
      section with Platform / Version / Last Reported rows.
      Last Reported uses the existing `FormatTimestamp` hook for
      "2 minutes ago" formatting.

  Passive telemetry only -- no enforcement gate. If we ever want to
  block old clients, the data model is already in place; add a
  policy table + middleware and the columns feed the check.

#### RFC 8252 §7.3 loopback redirect_uri support for native OAuth

The `POST /auth/native/begin` endpoint now accepts
`redirect_uri` values pointing at `http://127.0.0.1:*/callback` /
`http://localhost:*/callback` / `http://[::1]:*/callback`, in
addition to the custom `nexguard-connect://callback` scheme macOS
uses.

Windows can't register a custom URL scheme the same way macOS does
(no `LSSetDefaultHandlerForURLScheme` equivalent for
unprivileged apps); the RFC-blessed alternative is a loopback
`http://` redirect that the client's own OS process handles. This
change unblocks NexGuard Connect for Windows 0.1.0+ (WebView2
OAuth) without introducing any new scheme-registration plumbing.

Only loopback hosts (`127.0.0.1`, `localhost`, `::1`) are allowed
-- arbitrary external `http://` URLs are still rejected as a CSRF
guard.

---

## [3.0.9] - 2026-06-28

**Admin portal UX sweep — `frontend-design-direction` applied to
every major surface.** 24 commits across the whole admin section.
No schema changes — purely UI plus a handful of safety / correctness
fixes the redesign work surfaced.

The theme across every page: stats strip + status callout at top
(answers "is this surface healthy?" before scrolling), filter bars
on indexes, 4-zone Overview cards on show pages, confirm modals
for any toggle whose blast radius reaches users, lock-out guards
on delete flows, computed warnings instead of conditional-in-prose
disclosures, aria-label everywhere `title=` was hover-only, and
~150 inline `style="..."` declarations replaced with utility
classes across the suite.

### Redesigned surfaces

#### `/devices` and `/devices/:id`

  * Index stats strip (Total / Pending approval / Connected now /
    Stale) with `--warn/--ok/--muted` tile tints.
  * Status + Last Handshake columns collapsed into one Connection
    badge with six states (pending / connected / recent / idle /
    stale / never). Public Key + Created columns dropped from the
    shared partial — moved to the show page where they're
    forensically useful.
  * Filter bar — search by device name OR user email, plus Status
    and Connection chips.
  * Pending banner above the table when devices need triage;
    default sort = pending first, then handshake desc.
  * Show page: hero refresh, neutral stat-strip icons (replaces
    the colored-icon tiles dashboard v3.0.6 already dropped),
    consolidated approval/connection state, 2-column Network +
    WireGuard grid on desktop.
  * Pure-function helpers in `FzHttp.Devices` —
    `connection_state/1`, `connection_class/1`, `connection_label/1`,
    `connection_icon/1`, `relative_handshake/1` — used across admin
    index + show + user-detail Devices tab + unprivileged.

#### `/rules`

  * Side-by-side Allow/Deny grid → URL-addressable tabs
    (`/rules` → Allow, `/rules/deny` → Deny). Full table width
    per tab; mobile-clean.
  * Add-rule form lifted OUT of the table-first-row (was visually
    mixing input vs data row). Now a dedicated form-strip card
    above with explicit field labels.
  * Search by destination + user email; status / connection chips;
    Reset + `N of M` counter.
  * `.ng-form-actions--spaced` form-action spacing, dropped
    Bulma-era `gradient(135deg, ...)` panel icons + add button in
    favour of flat semantic colours.
  * Live CIDR validation hooked at the right layer so live
    feedback (kernel ≥ 5.6.9 requirement disclosure inline,
    not hover-only).

#### `/applications` and `/applications/:id`

  * Hero rebuilt via `.ng-app-hero` family. The show page lost 28
    inline `style="..."` declarations — most went to
    `.ng-detail-card-body`, `.ng-th-narrow`, `.ng-table-wrap--flush`,
    `.ng-section-meta`.
  * 4-zone Overview card (Routing · Policy · Access · Cert/TLS)
    replacing the stub 5-row `<dl>`.
  * `.ng-rule-action-badge--allow/--deny` family for L7 rule
    action pills (replaces two hardcoded `#fee2e2 / #b91c1c`
    inline styles on the deny badge).
  * Index search/filter (name OR hostname + status chip).
  * Cert-source picker demotes step_ca behind a `Pending` badge —
    library + upload remain the canonical paths until the step-ca
    pipeline lands.

#### `/access-groups` and `/access-groups/:id`

  * **Critical safety fix**: source-driven write guard. `:idp_sync`
    and `:system` groups now hide manual add/remove and the edit
    form — manual edits were silently overwritten on the next IdP
    sync. Member-row Remove buttons omitted from the table when
    not writable; the Overview Source zone shows an "Editable
    yes/no" pill.
  * URL-addressable tabs (Overview / Members / Danger).
  * 4-zone Overview (Identity · Source · Membership · L7 gate).
  * Index search/filter (name + description + source chip).
  * Hero matches `.ng-app-hero` shape; `title=` → `aria-label`.

#### `/settings/certificates`

  * Dedicated `.ng-cert-status-badge` family with `--healthy/
    --warning/--critical/--expired` variants. The old code
    repurposed `.ng-source-badge--manual` (slate) for expired
    and `.ng-source-badge--idp_sync` (green) for healthy —
    conflated the provenance palette with operational urgency.
  * Stats strip tints `.ng-stat-tile--danger` when
    critical/expired count > 0, `--warn` for expiring soon.
  * "Used by" hover tooltip → `<details>` disclosure with
    Pinned / Auto-matched hostname groups.
  * Replace modal now lists affected apps in an amber
    `.ng-modal-callout--warning` BEFORE the admin pastes new
    material — so a narrower-SAN replacement can be aborted
    before TLS breaks for auto-matched apps.
  * Filter bar (search label / SAN + expiry chip).

#### `/settings/l7`

  * Stats strip (Enforcement · Enabled apps · DNS forwarders ·
    Last update). Enabled-apps tile turns amber when L7 is on
    but zero apps are published (misconfig signal).
  * `.ng-cert-preview` misuse → `.ng-modal-callout--success` for
    the L7-active banner (the cert-preview class belongs to the
    TLS library, not org-wide status).
  * DNS save confirm modal — the previous plain submit could
    typo a primary IP and break in-flight name resolution for
    every VPN client within ~1s.
  * Hero badge switched from `.ng-scope-badge--all/--limited`
    (access-scope semantics) to `.ng-source-badge--idp_sync/
    --manual`.

#### `/settings/security`

  * Stats strip (Forced MFA / Local auth / VPN re-auth /
    SSO providers) plus a posture callout when the org is in a
    risky state (`:critical` — Force MFA OFF + Local Auth ON;
    `:warning` — Force MFA OFF, or Local Auth ON with zero SSO,
    or VPN sessions never expire).
  * **Sensitive toggles route through confirm modals**:
    `require_mfa`, `local_auth_enabled`, `disable_vpn_on_oidc_error`.
    Per-(key, direction) modal copy spells out the user impact —
    Force MFA OFF lands a danger-tone modal, Local Auth ON with
    no SSO lands a warning, etc.
  * **Lock-out guard on provider delete**: removing an SSO
    provider that would leave the org with zero sign-in methods
    triggers a `.ng-modal-callout--danger` and disables the Delete
    button until another sign-in path is armed.
  * Toggle ON/OFF labels via `.ng-toggle-state`.
  * SSO empty states with embedded "Add provider" CTA and
    provider-type-specific reasoning copy.
  * Provider tables: label + Config ID as primary + meta (was a
    full mono column).

#### `/settings/account`

  * Stats strip (MFA methods / API tokens N/25 / Active sessions /
    Role).
  * Active-sessions table — "this device" badge on rows whose
    `remote_ip` matches the current LV (best-effort heuristic).
  * MFA delete modal: computes `is_last` + `force_mfa` and shows
    a `.ng-modal-callout--danger` when both hold ("you will be
    forced to re-enroll on next sign-in") instead of the previous
    conditional-in-prose warning.
  * Account edit form harmonised with the user-form fix from
    v3.0.8 — `phx-change="validate"`, inline password inputs with
    the `.ng-field` family, email-change warning callout, "leave
    blank to keep" hint.
  * `.ng-provider-empty` empty states upgraded with title + hint +
    embedded CTA buttons.

#### `/settings/network`

  * **Confirm modal for Preserve Client IP** (no-MASQUERADE) on
    enable. The toggle silently rewrote nftables — clicking ON
    without a return route on destination servers broke traffic
    to internal subnets. Confirm modal now lists the affected
    CIDRs + spells out the return-route requirement.
  * Live CIDR list validation via new
    `FzHttp.Validator.validate_cidr_list/3`. Save button stays
    disabled until the changeset is valid (was just "has changes").
  * Toggle ON/OFF state label.
  * `FzWall.CLI.Live.reload_postrouting/0` — the helper was
    imported into the module but never re-exported, so every
    `:reload_masquerade` GenServer call had been crashing with
    `UndefinedFunctionError`. Now `defdelegate`d properly.

#### `/settings/audit_log`

  * **Free-text search** across actor_email / target_label /
    target_id / IP — the primary forensic affordance the page
    was missing.
  * Time-range chip (24h / 7d / 30d / 90d / all) — maps to the
    existing `:from` filter via `DateTime.add`.
  * Reset-filters button + empty-state variants (zero-ever vs
    zero-match vs page-beyond-data).
  * Result icon `title=` → `aria-label`.
  * Retention input uses `Integer.parse/1` with explicit
    range check — previously crashed the LV on empty / non-
    numeric input.

#### `/settings/client_defaults`

  * **DNS Servers field now forced to the gateway CoreDNS IP
    when L7 enforcement is on.** Backend `Devices.get_dns/2`
    overrides at read time so device configs always serve the
    right resolver — clients pointed at upstream DNS would
    NXDOMAIN every declared application hostname. UI disables
    the input + shows the override badge + explains the
    redirection in plain language.
  * Live validate, disabled-save until valid changes, info
    callout reframed around NexGuard Connect's auto-refresh
    behaviour (sign-in re-fetches config; no manual regeneration
    needed).
  * `binary_to_list/1` trims each CSV item — the
    binary_to_list ↔ list_value round-trip used to widen the
    Allowed-IPs textarea by one extra space per keystroke once
    live-validate landed.

#### `/settings/customization`

  * Override notice replaced with `.ng-modal-callout` info
    banner (drops two inline styles + a hardcoded `#2563eb`).
  * Success flash on Default/URL/Upload save handlers — they
    were silent.
  * `phx-disable-with` on all three submit buttons.

#### `/diagnostics/connectivity_checks`

  * Current-state callout at top — WAN online/offline + public
    IP + last-checked relative + failure count in last 20.
  * Failed-check rows now tinted red via `.ng-row--failure`.
  * `nil` fallbacks for HTTP code / resolved IP.

#### `/notifications`

  * "Clear all" button when count > 1 (the
    `Notifications.clear_all/1` context fn already existed).
  * Per-row severity tint (error red / warning amber / info
    neutral).
  * Dismiss button `title=` → `aria-label`.
  * Inline styles class-ified (5 → 0 across page + topbar badge).

### Cross-cutting

#### Safety + correctness fixes

  * `FzHttp.Validator.validate_cidr_list/3` — new helper.
    `Configuration.Changeset` now validates
    `gateway_no_masquerade_cidrs` per item; `"10.0.0.0"` without
    `/N` no longer slips through.
  * `FzWall.CLI.Live.reload_postrouting/0` — delegate fix (was
    crashing the network settings page).
  * `Devices.get_dns/2` — L7-aware override (force CoreDNS).
  * `Devices.connection_state/1` family — extracted helpers so
    every device-rendering surface shares the same logic.
  * `AuditLogs.apply_filters/2` — new `:search` clause with ILIKE
    across four columns.

#### Observability

  * Network settings: info logs on toggle commit + nftables
    reload (with state + CIDR count). The path was silent on
    success before — admin had no `docker compose logs -f` trail
    for masquerade flips.

#### Design tokens added

  * `.ng-modal-callout--danger` — warmer than `--warning`, for
    lock-out / Force-MFA-OFF / critical security-posture banners.
  * `.ng-cert-status-badge` family.
  * `.ng-rule-action-badge--allow/--deny`.
  * `.ng-conn-cell` family for device connection states.
  * `.ng-stat-tile--danger` / `--warn` / `--ok` / `--muted`
    modifiers.
  * `.ng-toggle-state` + `--on`.
  * `.ng-section-header { margin: 0 }` scoped inside
    `.ng-detail-card-header` — kills the
    `style="margin: 0"` inline override across 20+ usages.
  * `.ng-form-footer` (split form-footer hint + button).
  * `.ng-section-meta` (right-aligned card-header meta).
  * `.ng-row--pending` / `--stale` / `--failure` row tints.
  * `.ng-th-narrow` / `.ng-th-actions` / `.ng-td-nowrap`.

### Memory + ADR-adjacent

`Devices.get_dns/2` change is the first surface-level enforcement
of the NexGuard Connect auto-refresh behaviour (Connect re-fetches
device config on every sign-in via
`/api/v1/devices/me/config`) — when L7 is on, clients will
self-correct to the gateway CoreDNS without admin touching each
device.

### Deferred

  * Form-modal harmonisation for OIDC / SAML providers — bigger
    refactor, lower ROI now that the rest of `/settings/security`
    communicates state clearly.
  * Audit log CSV/JSON export, PubSub live tailing, severity-tag
    classifier — Pass 2 work.
  * "Sign out everywhere" affordance on `/settings/account` —
    needs session-store enumeration.
  * MFA freshness window (`require_mfa_age_seconds`) org-wide UI
    surface.
  * DRY refactor of repeated toggle rows + 3-clone confirm
    modals — pattern is consistent across the codebase.

---

## [3.0.8] - 2026-06-26

**Users domain redesign — full refresh of `/users`, `/users/:id`,
and the add/edit modal.** Applies the `frontend-design-direction`
skill across the three surfaces an admin touches daily when
managing identity. No schema changes — purely UI + a handful of
context additions for bulk operations.

### Added — `/users` (index)

#### Stats strip — Identity domain pulse

Five tiles mirroring the dashboard's domain-tile pattern: Total
users · Active 24h · MFA enrolled (%) · Admin count · Break-glass
count (only rendered when > 0, since `access_scope = :all` should
be rare + noteworthy).

#### MFA column — freshness, not just enrolment

The previous "Auth method" string didn't tell admin whether a user
could satisfy a `require_mfa_age_seconds` rule. The new column
shows:

  * `✓ 5m`  — at least one factor verified ≤30 days ago
  * `⚠ 45d` — enrolled but stale
  * `?`     — enrolled but never verified
  * `—`     — no factor enrolled

Drives off `mfa_methods.last_used_at` aggregated per user via the
new `User.Query.hydrate_index/1` — single LEFT JOIN, no N+1.

#### Last activity column

`max(last_signed_in_at, latest_device_handshake)` — the VPN
handshake is the strong activity signal in a ZTNA context.
Tooltip shows both raw values for forensic context.

#### Disabled row styling + break-glass marker

Disabled rows get muted background + strikethrough email + red
`[Disabled]` tag. `access_scope = :all` rows get an amber
`[break-glass]` tag. A status dot (green/gray) at the left of
the User cell mirrors the dashboard's session indicator.

#### Filter bar — search + 3 chips

Single-row bar above the table: email substring search
(`phx-debounce="200"`), Role chip (All / Admin / Unprivileged),
MFA chip (Any / Enrolled / None), Status chip (Active default /
All / Disabled). Filter runs in-memory over the already-loaded
list — NexGuard deployments are typically <100 users so the
expensive bit is the hydrate query, not the filter. `N of M`
counter + Reset button appear whenever any filter diverges.

#### Bulk actions — Disable / Enable / Delete

Reuses the toolbar pattern shipped for /devices in v3.0.4.
Checkbox column + header select-all (respects current filter),
sticky toolbar when selection > 0, delete behind a confirm modal
listing affected emails. Selected rows tint blue via the
existing `.is-row-selected`.

New context functions in `FzHttp.Users`: `disable_user/3` and
`enable_user/3` (subject-aware variants), plus `bulk_disable/3`
/ `bulk_enable/3` / `bulk_delete/3` which iterate + delegate
per row so each operation produces its own audit row (no opaque
"bulk" entries). The audit whitelist gains `user.enable` — was
missing because the existing `user.disable` action was the only
side-channel before this work.

### Added — `/users/:id` (show)

#### Three-line hero

Replaces the previous single-line breadcrumb + role + VPN badge
with three lines that answer "is this user OK?" in one glance:

  Line 1: avatar + breadcrumb + email + active/disabled dot
  Line 2: role + break-glass tag + Disabled tag
  Line 3a: MFA state (icon + freshness) · auth source
  Line 3b: device count · group count · last VPN handshake

State drives colour: MFA fresh = calm green, stale = amber, none =
red. Same active/disabled dot pattern as the Users index.

#### Overview card — 4-zone compact summary

Replaces the bloated `user_details.html.heex` partial on the show
page (partial still used by /user_account, untouched). 2×2 grid:

  Identity  — email · role · source · joined
  Security  — MFA · L7 scope · status
  Activity  — last sign-in · auth method · last VPN · last activity
  Access    — devices · groups · L3/L4 rules

Dense scan via 2-column `dl` per zone (max-content + 1fr columns)
with tabular-nums so counts and timestamps align vertically.

#### URL-addressable tabs

Splits the previous 1500px vertical scroll into 6 URL-addressable
tabs. Same LiveView module + event handlers; the template gates
each existing card on `@tab` derived from the live_action:

  /users/:id              → Overview
  /users/:id/devices      → Devices    (table + Add Device)
  /users/:id/groups       → Groups     (memberships + add picker)
  /users/:id/access       → Access     (L7 scope toggle)
  /users/:id/connections  → Connections (OIDC list + empty state)
  /users/:id/danger       → Danger      (VPN toggle + Promote + Delete)

Tab nav matches the Applications Show pattern: soft `<.link patch>`
swaps, count badges on Devices / Groups / Connections, Danger
styled with the red accent. Edit and Add Device modals overlay
the right tab (Add Device auto-surfaces Devices underneath so
closing lands in the correct place).

#### Typography normalised across tabs

Previously Devices / Groups / Access tabs looked larger than
Overview — root cause was `.ng-form-hint` being referenced in
templates but never defined in SCSS (browser fallback ~1rem
vs Overview's tight 0.82rem `dl`). Defined `.ng-form-hint`
properly + added `.ng-detail-card-body` family to replace
scattered inline `style="padding..."` declarations. Tables in
Devices / Groups stay table-typography (intentional — table
cells have their own rhythm).

### Added — `/users/new` + `/users/:id/edit` (form modal)

#### Field chrome harmonised

The email field was using the modal family (`.ng-field` / `.ng-label`
/ `.ng-input`) while the two password inputs came from a shared
partial that emits the settings family (`.ng-setting-input`). All
three fields now share the modal family. The shared partial is
unchanged — still used by /settings and /user_account.

#### Email-change warning on edit

An amber `.ng-modal-callout--warning` callout at the top of the
edit modal spells out: "Email is the user's sign-in identity and
the OIDC/SAML linkage key. Changing it may break login until the
user re-authenticates with the new address." Editing email
without the warning was a footgun — the field doubles as the OIDC
linkage key, so a stealth edit could silently desync identity
from the upstream IdP.

#### Smaller fixes

  * `x-autocomplete="off"` (dead Alpine prefix) → plain
    `autocomplete="off"` plus per-input attrs. Email gets
    `spellcheck="false"`.
  * "Leave blank to keep the current password." hint under the
    password field on edit so admins don't think the field is
    required.
  * Submit button copy per action — "Create user" on /new,
    "Save changes" on /edit (instead of generic "Save").
  * Modal title sentence-case ("Add user" / "Edit \<email>").

### Removed

  * **VPN Status column** from `/users` — the dashboard's Live
    Sessions panel (v3.0.7) covers "who is connected right now";
    the per-row column was 99% "Not connected" noise.
  * **Created column** from `/users` — replaced by Last activity,
    which is what admins actually care about daily.

### Notes

Phase U-Show-C (modal partial extraction) deferred indefinitely —
Phoenix LiveView 0.18 doesn't ship `embed_templates`, so a clean
partial include requires a function-component refactor. The four
confirm modals (Delete / Promote / Remove-group / Scope-change)
stay inline above the tab content; they overlay regardless of
which tab is active, so functionally nothing changes.

Phase E-Form-B (role select at create) and E-Form-C (password
"Change password" disclosure on edit) intentionally deferred.

---

## [3.0.7] - 2026-06-26

**Dashboard Phase B — compliance scorecard + live VPN sessions.**
Completes the dashboard redesign begun in v3.0.6 by adding the two
deferred zones below the hero/stats/activity strip.

### Added

#### Zone 4 — Security compliance scorecard

Different in spirit from the hero alerts (which suppress passes and
only fire on problems). The compliance list shows EVERY check with
its current state — admins get reassurance the baseline is met,
not just notification when it isn't. Passing rows are visually
muted (low ink); failures stand out by colour, not position.

Seven checks, fixed order so the layout becomes muscle memory:

| Check | OK condition |
|---|---|
| Force MFA | `require_mfa = true` |
| MFA enrolment | ≥95% of users have a factor (≥80% = info) |
| VPN session TTL | `vpn_session_duration > 0` |
| Auth surface | No bypass path (pure local / pure SSO / mixed + Force MFA) |
| TLS certificates | All valid >30 days, no expired |
| L7 app authorisation | No enabled app with zero allowed groups |
| Service health | DB / proxy / CoreDNS all `:ok` |

Each row carries label + plain-language detail + status badge
(OK / Info / Review / Action). Click "Configure →" in the header
jumps to `/settings/security`.

#### Zone 5 — Live VPN sessions

Lists up to 8 devices that handshook within the last 3 minutes —
"who's connected RIGHT NOW". Each row: pulsing green dot, device
name (deep link to /devices/<id>), user email, VPN IP, "Xm ago"
relative handshake time. Click "All devices →" for the full list.

Single Ecto query (`Device.latest_handshake >= ago(180, "second")`)
preloading `:user` for the email column, ordered by handshake desc.
Cap at 8 entries; empty state shows "No devices connected in the
last 3 minutes."

### Layout

Two-column grid below the activity feed at desktop, stacks at
≤1024px. Both panels share the existing `.ng-detail-card` chrome
so they read as siblings to the rest of the dashboard.

---

## [3.0.6] - 2026-06-26

**Dashboard redesign — Phase A.** Health-first ops surface for the
admin portal. Single-glance "is the system healthy?" answer, four
domain-grouped stat tiles, and a recent-activity feed. No schema
changes, no migration. Live on prod, untagged.

### Added

#### `/dashboard` redesigned around health, not navigation

Applies the `frontend-design-direction` skill — the dashboard is an
ops tool that admins look at multiple times a day, so it should
answer "is the system healthy right now?" in <2 seconds rather
than serve as a navigation hub (the sidebar already does that).

Five zones, three shipped in Phase A:

  * **Hero status banner** (Zone 1) — single-line health summary
    with an aggregate severity (ok / info / warn / critical) that
    drives the entire banner colour. Sub-line carries the L7 stack
    pulse: enforcement on/off · apps count · enabled count · bundle
    version + age. When alerts are present they list below the
    headline with severity-coloured left borders + deep-link
    "Review →" actions.

  * **Domain-grouped stat strip** (Zone 2) — four tiles by domain
    (Identity / Network / L7 ZTNA / Activity), each with one
    headline metric plus two sub-metrics with semantic dots
    (ok/warn/critical/info). Each tile is a click-through to its
    primary admin page. Responsive: 4→2→1 columns at 1024/540px.

  * **Recent activity feed** (Zone 3) — last 8 audit log entries
    embedded directly, four-column grid (time | category badge |
    target | actor) for top-to-bottom log scanning. "View full
    audit log →" link to the v3.0.3 inline diff viewer.

Zones 4-5 (Security checks rebuilt + Live VPN sessions) deferred to
Phase B.

#### Hero alerts — surface silent misconfigurations

Each alert is conditional, only fires when the org is in the risky
state. A correctly configured deployment sees none of them; the
banner stays green.

  * `cert_expired` (:critical) — at least one TLS cert in the
    library is past `not_after`. Deep link to /settings/certificates.
  * `cert_critical` (:critical) — cert expiring within 7 days.
  * `cert_warn` (:warn) — cert expiring within 30 days
    (suppressed if `cert_critical` is also active to avoid noise).
  * `mfa_low_coverage` (:warn) — MFA enrolment < 80% AND Force-MFA
    off. Deep link to /settings/security.
  * `pending_devices` (:info) — at least one device awaiting
    approval. Deep link to /devices.
  * `stale_devices` (:info) — > 10 devices idle for > 30 days
    (was previously `> 0` in the old security panel — too noisy).
  * `service_health` (:critical) — DB / proxy / CoreDNS reports
    `:down` or `:degraded`. Reuses the HealthMonitor snapshot the
    topbar dots already poll.
  * `l7_idle` (:info) — L7 enforcement is ON but no apps are
    enabled — proxy bundle compiled but routes nothing.
  * `orphan_enabled_apps` (:critical) — app is `enabled = true` but
    has zero allowed groups. The v3.0.5 fail-closed work made these
    apps silently unreachable; this alert surfaces them so the
    silent failure stops being silent. Deep link to the offending
    app's Groups tab (single-app case) or the apps list (multiple).
  * `session_never_expires` (:info) — `vpn_session_duration = 0`.
    A leaked credential keeps VPN access indefinitely; standard
    ZTNA practice is a TTL.
  * `mixed_auth_no_force_mfa` (:warn) — local password auth is
    enabled AND an SSO provider is configured AND Force MFA is off.
    SSO MFA enforced at the provider level is bypassed by anyone
    using the local `/sign_in` form. Fix is either disable local
    auth or enable Force MFA in NexGuard.

### Removed

  * **Quick Actions panel** — six buttons that duplicated the
    sidebar entries (Manage Users, Manage Devices, Firewall Rules,
    Security Settings, Customization, WAN Diagnostics). The
    sidebar already serves navigation; the dashboard should serve
    health visibility.
  * **Per-card random colour scheme** (blue/indigo/green/amber on
    the four stat cards). Replaced by state-driven colour — dots
    and badges carry semantic meaning only.

### Defensive

All auxiliary calls in `assign_all/1` are wrapped in `try/rescue`
that fall back to safe empty/unknown values: a mis-bootstrapped
HealthMonitor, BundleBuilder, or cert library cannot crash the
dashboard. A fresh DB pre-bootstrap renders an "all operational"
banner with empty stats instead of a 500.

---

## [3.0.5] - 2026-06-26

**Admin-portal DNS forwarder configuration + ZTNA policy hardening.**
Two BREAKING behavior changes — read the migration notes below
before deploying. Live on prod, untagged.

### ⚠ Breaking — read first

#### Empty `allowed_groups` is now fail-closed

Pre-v3.0.5: an enabled app with NO allowed groups + an `allow` L7
rule was reachable by every authenticated VPN user (the proxy's
group gate skipped on empty list). This contradicted ZTNA
conventions (Cloudflare Access, Tailscale, IAP all fail-closed).

Now both proxy + Phoenix enforce: "no allowed groups" = "no one
allowed", not "everyone allowed".

  * **Proxy** (`policy.Decide`): empty `AllowedGroupIDs` short-
    circuits to deny BEFORE rule eval. Distinct log reason
    `group gate: app has no allowed groups (fail-closed)`.
  * **Phoenix** (`set_application_enabled/4`): refuses
    `enable = true` if the app has zero allowed_group rows. Clear
    error at toggle time: "cannot enable without at least one
    allowed access group — add a group on the Groups tab".

**Migration check before deploy:**

```sql
SELECT a.hostname, a.enabled,
       (SELECT COUNT(*) FROM application_allowed_groups ag
        WHERE ag.application_id = a.id) AS group_count
FROM applications a
WHERE a.enabled = true
ORDER BY group_count, a.hostname;
```

Any row with `group_count = 0` will become unreachable after the
proxy upgrade. Add groups via /applications/<id>/groups BEFORE
deploying the proxy, OR deploy Phoenix first (changeset guard
blocks new mis-configurations) then audit existing apps.

#### CoreDNS Corefile is now generated, not bind-mounted

`docker-compose.coredns.yml` no longer mounts `coredns/Corefile`
read-only. Phoenix writes `/etc/nexguard/Corefile.generated` from
DB-backed org_settings; CoreDNS' `reload 2s` plugin picks it up.

  * `.env` `COREDNS_FORWARD_TO` is now a **bootstrap-only** seed:
    on a fresh deployment Phoenix reads it once to populate the DB,
    then ignores subsequent edits. Admins edit upstreams via the
    portal (`/settings/l7` → "DNS forward upstreams" card).
  * Multi-value supported native (the `{$VAR}` one-token limitation
    is gone since Phoenix templates the Corefile itself). Both
    primary AND fallback fields accept comma-separated lists.
  * New `coredns-init` busybox sidecar gates CoreDNS startup on the
    generated Corefile existing — fixes a boot race where CoreDNS
    crash-looped during the ~2s before Phoenix's bootstrap_dns/0
    finished.

### Added

#### DNS forwarder config in admin portal

  * Migration `20260624000003_add_coredns_forward_to_org_settings`
    adds `coredns_forward_to` + `coredns_forward_to_fallback` as
    PostgreSQL `text[]` on the `org_settings` table.
  * New `FzHttp.L7.CoreDnsCorefile` GenServer — sibling of
    `CoreDnsHosts`. Subscribes to `nexguard:l7:settings`, regenerates
    `/etc/nexguard/Corefile.generated` on every `set_dns_forward/4`
    via atomic tmp+rename.
  * `OrgSettings.set_dns_forward/4` — context API with full audit
    trail (new whitelist action `org_settings.dns_forward.change`).
  * `OrgSettings.seed_dns_from_env/2` — first-boot helper called
    from `FzHttp.Application.bootstrap_dns/0`.
  * UI: `/settings/l7` gets a "DNS forward upstreams" card with two
    comma-separated input fields (primary required, fallback
    optional) + "last edited" relative timestamp.

#### CoreDNS production tuning

Generated Corefile now ships with the production-grade settings
from the design review:

```corefile
. {
  bind 0.0.0.0
  bufsize 1232                       # EDNS0 ceiling for VPN MTU 1280
  template ANY ANY local lan home internal corp { rcode NXDOMAIN }
  hosts /etc/nexguard/internal-hosts {
    reload 1s; ttl 30; fallthrough .
  }
  forward . <upstreams> {
    prefer_udp
    max_concurrent 1000             # was 100 — bind9 RRL-exempt
    health_check 5s
    expire 30s
    policy sequential
  }
  cache {
    success 16384 3600 60
    denial 4096 300 30
    serve_stale 1h immediate
    prefetch 10 1m 10%
  }
  loop                              # detect forwarding loops
  loadbalance                       # shuffle multi-IP A records
  errors
  log . "..."                       # full per-query audit
  reload 2s
  prometheus :9153                  # cache hit / forward latency
}
```

Container limits also bumped:

  * `ulimits.nofile: 65535/65535` — accommodate the larger forward
    connection pool.
  * `logging: max-size 1g, max-file 10` — 10GB rolling buffer per
    container for the full query log (~3-4 weeks of forensic
    history at 20 VPN clients).

### Fixed

  * Settings changeset regex (`~r{...\d...}i`) failed to compile on
    Elixir 1.14 — switched to `~r/.../` form with three short
    patterns (IPv4 / IPv6 / hostname).
  * CoreDNS `reload 1s` would refuse to start — minimum is 2s.
  * Initial Corefile bootstrap race — CoreDNS crash-looped opening
    a not-yet-written `Corefile.generated`. Added a `coredns-init`
    busybox sidecar that polls for the file before letting the
    `coredns` service start (depends_on:
    `service_completed_successfully`). The CoreDNS image is
    distroless so wrapping its own entrypoint in `sh -c` wasn't an
    option — discovered the hard way.

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
