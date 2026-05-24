# NexGuard

**NexGuard** là một VPN server tự host và Linux firewall do **Lê Bình Phương** phát triển và duy trì, dựa trên nền tảng Firezone 0.7 (legacy).

- Tác giả: Lê Bình Phương
- Email: me@binhphuong.io.vn
- Image: `binhphuong/nexguard`

## Giới thiệu

NexGuard cung cấp giải pháp VPN tự host với giao diện quản trị web đơn giản, xây dựng trên nền tảng WireGuard® và nftables. Triển khai trên hạ tầng của bạn để kiểm soát toàn bộ lưu lượng mạng.

## Features

- **Fast:** Uses WireGuard® to be
  [3-4 times](https://wireguard.com/performance/) faster than OpenVPN.
- **SSO Integration:** Authenticate using any identity provider with an OpenID
  Connect (OIDC) connector.
- **Containerized:** All dependencies are bundled via Docker.
- **Simple:** Takes minutes to set up. Manage via a simple CLI.
- **Secure:** Runs unprivileged. HTTPS enforced. Encrypted cookies.
- **Firewall included:** Uses Linux [nftables](https://netfilter.org) to block
  unwanted egress traffic.

### Anti-features

NexGuard is **not:**

- An inbound firewall
- A tool for creating mesh networks
- A full-featured router
- An IPSec or OpenVPN server

## Quick Start

```bash
# Production (Docker Compose)
cp .env.example .env   # fill in secrets
docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml run --rm nexguard bin/migrate
docker compose -f docker-compose.prod.yml run --rm nexguard bin/create-or-reset-admin
```

## Security

See [SECURITY.md](SECURITY.md).

## License

See [LICENSE](LICENSE).

WireGuard® is a registered trademark of Jason A. Donenfeld.
