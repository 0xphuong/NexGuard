# NexGuard

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Self-hosted VPN server and Linux firewall built on [WireGuard®](https://wireguard.com) and [nftables](https://netfilter.org). Deploy on your own infrastructure and manage devices, users, and egress rules through a web UI.

Maintained by [Lê Bình Phương](https://binhphuong.io.vn) · Docker image: `ghcr.io/0xphuong/nexguard`

> Forked from [Firezone 0.7](https://github.com/firezone/firezone).

## Features

- **Fast** — WireGuard® is [3–4×](https://wireguard.com/performance/) faster than OpenVPN
- **SSO Integration** — OIDC and SAML 2.0 support for any identity provider
- **Firewall included** — per-user and global egress rules via nftables
- **Simple** — web admin UI, single CLI binary (`nexguard-ctl`), or Docker Compose
- **Secure** — runs unprivileged, HTTPS enforced, encrypted cookies

### Non-goals

NexGuard is **not** an inbound firewall, mesh networking tool, full-featured router, or IPSec/OpenVPN server.

## Quick Start

### Docker Compose (recommended)

```bash
cp .env.example .env          # fill in EXTERNAL_URL, DEFAULT_ADMIN_EMAIL, etc.
# or generate secrets automatically:
# bash rel/overlays/bin/gen-env > .env

docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml run --rm nexguard eval "FzHttp.Release.migrate"
docker compose -f docker-compose.prod.yml run --rm nexguard eval "FzHttp.Release.create_admin_user"
```

### Omnibus package

```bash
curl -fsSL https://raw.githubusercontent.com/0xphuong/NexGuard/main/scripts/omnibus_install.sh | bash
```

After install, manage with `nexguard-ctl`:

```bash
nexguard-ctl reconfigure
nexguard-ctl create-or-reset-admin
nexguard-ctl status
```

## Security

See [SECURITY.md](SECURITY.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache 2.0. See [LICENSE](LICENSE).

WireGuard® is a registered trademark of Jason A. Donenfeld.
