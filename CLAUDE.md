# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

NexGuard (upstream: Firezone 0.7, legacy/EOL) is a self-hosted WireGuard VPN server + Linux nftables firewall. The custom Docker image is published as `binhphuong/nexguard`.

## Development Commands

### Setup (Docker-based)
```bash
docker compose up -d postgres
docker compose run --rm nexguard mix do ecto.setup, ecto.seed
docker compose up
# Login: firezone@localhost / firezone1234
```

### Common Mix Tasks (run from repo root)
```bash
mix test                          # run all tests (auto-creates and migrates DB)
mix test apps/fz_http/test/path/to/file_test.exs  # single test file
mix test apps/fz_http/test/path/to/file_test.exs:42  # single test at line
mix coveralls.html --umbrella     # coverage report → cover/
mix format                        # auto-format all Elixir
mix format --check-formatted      # check formatting (CI)
mix credo --strict                # lint
mix dialyzer                      # type analysis (slow first run, builds PLT)
```

### DB Management
```bash
mix ecto.setup    # create + migrate
mix ecto.seed     # create + migrate + seed with dev fixtures
mix ecto.reset    # drop + setup
mix ecto.migrate  # run pending migrations
```

### Production Bootstrap (required after first deploy or fresh DB)
```bash
docker compose -f docker-compose.prod.yml run --rm nexguard bin/migrate
docker compose -f docker-compose.prod.yml run --rm nexguard bin/create-or-reset-admin
```
`bin/create-or-reset-admin` reads `DEFAULT_ADMIN_EMAIL` and `DEFAULT_ADMIN_PASSWORD` from `.env`. Password must be **12–64 characters**. If the user already exists it resets the password; otherwise creates it fresh.

### Building the Docker Image
```bash
docker build -f Dockerfile.prod -t binhphuong/nexguard:<version> .
```

### Static Analysis (pre-commit runs all of these)
```bash
SKIP=no-commit-to-branch pre-commit run --all-files
```

## Architecture

### Elixir Umbrella — Three Apps

**`apps/fz_http`** — Phoenix web app. Contains all business logic, the database, and the HTTP/LiveView interface. All other apps depend on it.
- Domain contexts: `Users`, `Devices`, `Rules`, `ApiTokens`, `Config`, `ConnectivityChecks`, `Auth`
- Web layer: Phoenix LiveView for admin UI, REST JSON API under `/v0/`
- `FzHttp.Server` (GenServer) — the bridge: called by `fz_vpn` and `fz_wall` on boot to load initial state, and receives stats pushes from `fz_vpn` every 60s
- Config precedence: **env vars → DB → hardcoded defaults** (see `lib/fz_http/config/`)

**`apps/fz_vpn`** — WireGuard peer management.
- `FzVpn.Server` (GenServer) — maintains peer state, applies diff-based config updates to minimize disruption
- `FzVpn.StatsPushService` — every 60s calls `Interface.dump("wg-nexguard")` and pushes `rx_bytes`/`tx_bytes`/`latest_handshake` to `FzHttp.Server`
- Adapter pattern: `WgAdapter.Live` (production, wraps `Wireguardex` NIF) vs `WgAdapter.Sandbox` (in-memory GenServer for tests)
- Keypair persisted at `/var/nexguard/private_key` (chmod 0600), loaded or generated on boot

**`apps/fz_wall`** — nftables firewall.
- `FzWall.Server` (GenServer) — owns a MapSet of `{users, devices, rules}`, serializes all nft operations
- `CLI.Live` (production) runs shell `nft` commands; `CLI.Sandbox` is a no-op for tests
- Per-user model: each user gets a dedicated chain (`user{uuid}`) and 8 named sets (IPv4/IPv6 × accept/drop × IP/layer4)
- Chain `forward` matches packet source against `user{uuid}_ip_devices` → jumps to user chain → per-user accept/drop rules → falls through to global rules

### Data Flow: Device Lifecycle

```
create_device (fz_http)
  → IP allocated via PostgreSQL advisory lock
  → FzVpn.Server: add WireGuard peer (kernel)
  → FzWall.Server: nft add element to ip_devices set

delete_device (fz_http)
  → FzVpn.Server: remove peer
  → FzWall.Server: nft delete element
  → DB delete

Boot sequence:
  fz_wall → fz_http.load_settings → restore nftables state from DB
  fz_vpn  → fz_http.load_peers   → configure WireGuard interface
```

### Authentication Stack

Identity provider options (configured in DB via admin UI or env):
1. **Local** — email + Argon2 password (enabled by default; `local_auth_enabled` in `configurations` table)
2. **OIDC** — Ueberauth + `OpenIDConnect`; access tokens refreshed every 10 min by `Auth.OIDC.RefreshManager`
3. **SAML** — Samly library
4. **MFA** — NimbleTOTP second factor, enforced via `LiveMFA` hook on all authenticated LiveViews

Guardian (JWT) handles session tokens; Cloak (AES-256-GCM) encrypts sensitive DB fields (OIDC tokens, PSKs).

### nftables Rule Structure

```
table inet nexguard {
  # Global sets: ip_accept, ip_drop, ip_accept_layer4, ip_drop_layer4 (+ ip6 variants)
  # Per-user sets: user{uuid}_ip_{accept,drop}[_layer4], user{uuid}_ip{6}_devices
  # Per-user chains: user{uuid}

  chain forward {  # hook: filter
    ip saddr @user{uuid}_ip_devices → jump user{uuid}
    # ... global accept/drop rules last
  }

  chain postrouting {  # hook: nat/srcnat
    oifname "eth0" masquerade  # with RETURN rules for internal subnets (no NAT)
  }
}
```

Rule priority inside a user chain: L4 accept → L4 drop → IP accept → IP drop.

## Key Configuration

| Env Var | Effect |
|---|---|
| `WIREGUARD_IPV4_NETWORK` | IP pool for WireGuard peers |
| `LOCAL_AUTH_ENABLED` | Sets `configurations.local_auth_enabled` on first migration |
| `DATABASE_ENCRYPTION_KEY` | Cloak key — changing this breaks all encrypted DB fields |
| `EXTERNAL_URL` | Must match the public URL — used for cookies and OIDC redirects |

## Deployment Options

- **Docker Compose production**: `docker-compose.prod.yml` — Caddy (host network) + NexGuard (172.25.0.100) + Postgres
- **Ansible**: `ansible/ansible/playbook.yml` — roles: network, postgres, nexguard, caddy
- **Kubernetes**: `k8s-ingress-zerotrust.yaml` — external-nginx ingress to static endpoint `10.0.235.9:13000`
