# Changelog

All notable changes to NexGuard will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
