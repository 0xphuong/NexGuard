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
docker compose -f docker-compose.prod.yml run --rm nexguard bin/create-or-reset-admin
```

> **Tip — reset admin password manually:** If `RESET_ADMIN_ON_BOOT=false` (default) and you need to reset the admin account without restarting, run:
> ```bash
> docker compose -f docker-compose.prod.yml run --rm nexguard bin/create-or-reset-admin
> ```
> This re-creates or resets the admin user using the current `DEFAULT_ADMIN_EMAIL` and `DEFAULT_ADMIN_PASSWORD` values in `.env`.

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

## NexGuard Connect (VPN client)

One-liner install for the desktop client:

```bash
# macOS
curl -fsSL https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.sh | bash

# Linux (Ubuntu 20.04+ / Debian, needs root)
curl -fsSL https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.sh | sudo bash
```

Windows (PowerShell **as Administrator**):

```powershell
irm https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.ps1 | iex
```

Each script fetches the manifest, downloads the matching artifact (DMG / `.deb` / MSI), verifies SHA-256, and installs silently. On macOS it also strips the Gatekeeper quarantine so the app launches without the "Apple could not verify" prompt.

Uninstall: `bash -s -- --uninstall` (macOS/Linux) or `& ([scriptblock]::Create((irm .../install.ps1))) -Uninstall` (Windows). See [`nexguard-releases`](https://github.com/0xphuong/nexguard-releases) for all release artifacts + changelogs.

## Forward Traffic Without NAT (Preserve VPN Client IP)

By default NexGuard masquerades all outbound traffic, so destination servers see the gateway IP instead of the VPN client's real IP. To disable NAT for specific internal subnets (so servers on those subnets see the actual VPN client IP), set `GATEWAY_NO_MASQUERADE_CIDRS` in `.env`:

```bash
# .env
GATEWAY_NO_MASQUERADE_CIDRS=10.0.0.0/16,10.10.0.0/24
```

NexGuard will automatically add `nftables` RETURN rules for those subnets on startup — traffic to those destinations is forwarded as-is.

> **Requirement:** The destination server (or its upstream router) must have a return route to the WireGuard subnet, e.g.:
> ```bash
> ip route add 10.0.55.0/24 via <nexguard-ip-on-that-network>
> ```

### Auto-add host route for the WireGuard subnet

When running via Docker Compose, the host machine needs a route to the WireGuard subnet (`10.0.55.0/24`) pointing into the NexGuard container. Create a systemd service to add it automatically whenever Docker brings up the `br-nexguard` bridge:

```bash
sudo tee /etc/systemd/system/nexguard-route.service > /dev/null <<'EOF'
[Unit]
Description=NexGuard VPN subnet route
BindsTo=sys-subsystem-net-devices-br\x2dnexguard.device
After=sys-subsystem-net-devices-br\x2dnexguard.device
StartLimitBurst=15
StartLimitIntervalSec=60

[Service]
Type=oneshot
ExecStart=/bin/ip route replace 10.0.55.0/24 via 172.25.0.100 dev br-nexguard
RemainAfterExit=yes
Restart=on-failure
RestartSec=3

[Install]
WantedBy=sys-subsystem-net-devices-br\x2dnexguard.device
EOF

sudo systemctl daemon-reload
sudo systemctl enable nexguard-route.service
```

The service triggers automatically when `br-nexguard` comes up (on boot or after `docker compose up`) and retries until Docker finishes configuring the bridge. Adjust the subnet and gateway IP to match your `WIREGUARD_IPV4_NETWORK` and the container's fixed IP in `docker-compose.prod.yml`.

## Security

See [SECURITY.md](SECURITY.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache 2.0. See [LICENSE](LICENSE).

WireGuard® is a registered trademark of Jason A. Donenfeld.
