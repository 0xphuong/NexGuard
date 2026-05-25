# Changelog

All notable changes to NexGuard will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Complete rebranding from Firezone to NexGuard across all source files, configs, and documentation

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

[Unreleased]: https://github.com/0xphuong/NexGuard/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/0xphuong/NexGuard/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/0xphuong/NexGuard/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/0xphuong/NexGuard/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/0xphuong/NexGuard/releases/tag/v1.0.0
