# Changelog

All notable changes to NexGuard will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/0xphuong/NexGuard/compare/v1.1.2...HEAD
[1.1.2]: https://github.com/0xphuong/NexGuard/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/0xphuong/NexGuard/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/0xphuong/NexGuard/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/0xphuong/NexGuard/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/0xphuong/NexGuard/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/0xphuong/NexGuard/releases/tag/v1.0.0
