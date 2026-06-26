# NexGuard — Tổng hợp Logic & Kiến trúc

> Cập nhật: 2026-05-25  
> Image production: `binhphuong/nexguard:1.1.2`  
> URL production: `https://nexguard.binhphuong.io.vn`

---

## 1. Tổng quan

**NexGuard** (tên nội bộ: *NexGuard*) là VPN server tự host + Linux firewall dựa trên **WireGuard**, xây dựng bằng **Elixir/Phoenix** (phiên bản legacy 0.7.x). Hệ thống cung cấp:

- Tunnel VPN encrypted qua WireGuard (UDP 51820)
- Web admin UI (Phoenix LiveView, port 13000)
- Per-user egress firewall dùng nftables
- SSO/OIDC/SAML integration
- Multi-deployment: Docker Compose, Ansible, Kubernetes

---

## 2. Kiến trúc tổng thể

```
Internet
    │
    ▼
[Caddy :443] ─── reverse proxy ──► [NexGuard :13000] (Phoenix Web + API)
    │                                       │
    │                               ┌───────┼────────────┐
    │                               │       │            │
    │                          [fz_http] [fz_vpn]   [fz_wall]
    │                          Web/API  WireGuard   nftables
    │                                       │
    │                               [wg-nexguard]
    │                               WireGuard iface
    │                               IPv4: 10.0.55.0/24
    │                               IPv6: fd00::/106
    │
    ▼
[WireGuard Client] ──UDP:51820──► Tunnel ──► [Internal Networks]
                                              10.0.0.0/8
                                              10.2.0.0/16
                                              10.8.0.0/16
                                              ...

[PostgreSQL :5432] ─── data ──► NexGuard (users, peers, rules)
```

---

## 3. Elixir Application Structure

Dự án là **Elixir umbrella** với 3 app con:

---

### `apps/fz_http` — Phoenix Web Application

#### 3.1 Supervisor Tree (`application.ex`)

Khởi động theo 3 mode:
- **full** — toàn bộ services (production)
- **test** — có Ecto sandbox
- **database** — chỉ Repo (migration jobs)

#### 3.2 Domain Contexts

Mỗi context có cấu trúc chuẩn: `context.ex` + `schema.ex` + `changeset.ex` + `query.ex` + `authorizer.ex`

**Users (`lib/fz_http/users/`)**
- Schema: `email`, `password_hash` (Argon2), `role` (admin/unprivileged), `disabled_at`
- Operations: create, update, disable (set `disabled_at`), delete
- Auth: email+password qua Argon2; OIDC qua `oidc/connection`

**Devices (`lib/fz_http/devices/`)**
- Schema: `user_id`, `name`, `public_key`, `preshared_key`, `ipv4`, `ipv6`, `description`, `use_site_to_site_vpn`, `allowed_ips`, `dns`, `mtu`, `endpoint`, `persistent_keepalive`, `rx_bytes`, `tx_bytes`, `latest_handshake`
- IP allocation: dùng **PostgreSQL advisory locks** để tránh race condition khi cấp IP từ pool `WIREGUARD_IPV4_NETWORK` / `WIREGUARD_IPV6_NETWORK`
- Stats updater: tách `rx_bytes`, `tx_bytes`, `latest_handshake` từ WireGuard dump

**Rules (`lib/fz_http/rules/`)**
- Schema: `user_id` (null = global), `destination` (CIDR/IP), `action` (accept/drop), `port_range`, `port_type` (tcp/udp/any)
- Áp dụng per-user hoặc global (null user_id)

**API Tokens (`lib/fz_http/api_tokens/`)**
- Tối đa 25 tokens/user
- Schema: `token` (hashed), `expires_at`, `name`
- Dùng cho REST API authentication

**Configuration (`lib/fz_http/config/`)**
- Precedence: **env vars > database > defaults**
- Type casting: boolean, integer, array, JSON
- Embedded schemas: `OpenIDConnectProvider`, `SAMLIdentityProvider`
- DB-backed: logo upload, OIDC providers, SAML providers, email config, `require_mfa`
- Env-backed: secrets, WireGuard network, database DSN
- Changeset (`configuration/changeset.ex`): mọi field DB-backed phải có trong `@fields` để `cast/3` không bỏ qua khi save

**Connectivity Checks (`lib/fz_http/connectivity_checks/`)**
- GenServer poller kiểm tra kết nối Internet định kỳ
- Kết quả lưu DB, hiển thị trên admin UI

#### 3.3 Authentication Stack

```
Request
  │
  ├── HTML pipeline ──► Guardian (JWT cookie) ──► LiveAuth hook
  │                          │
  │                    LiveMFA hook (TOTP check + Force MFA enforcement)
  │
  └── JSON pipeline ──► Guardian (Bearer token / API token)
                             │
                        RequireMFA plug (403 nếu Force MFA bật và user chưa enroll)

Auth methods:
  1. Email + Password (Argon2)
  2. OIDC (Ueberauth) — Google, Okta, Azure AD...
  3. SAML (Samly) — enterprise IdP
  4. MFA (NimbleTOTP) — TOTP second factor
```

**Force MFA** (`require_mfa` config):
- Khi bật: user chưa có MFA method bị redirect đến trang đăng ký MFA thay vì tiếp tục
  - Admin → `/settings/account/register_mfa`
  - Unprivileged → `/user_account/register_mfa`
- Trang `register_mfa` được loại trừ khỏi kiểm tra (tránh redirect loop)
- API `/v0`: `FzHttpWeb.Plug.RequireMFA` trả về `403 + JSON error` nếu user chưa enroll
- Toggle tại **Settings → Security → "Force MFA for All Users"**

**OIDC Refresh Manager** (`oidc/refresh_manager.ex`):
- GenServer chạy mỗi **10 phút**
- Refresh access tokens cho tất cả OIDC connections
- Nếu refresh thất bại → revoke session → force re-login

**SAML** (`auth/saml/start_proxy.ex`):
- Cấu hình Samly provider từ DB config
- Redirect về IdP, nhận assertion, map về user

#### 3.4 Authorization Model

```elixir
# Mỗi resource có authorizer riêng
defmodule FzHttp.Users.Authorizer do
  # Admin: full CRUD
  # Unprivileged: chỉ edit own profile
end

# Check trong controller/live view:
FzHttp.Auth.authorize!(subject, :manage, %Device{})
```

Permissions được collect từ tất cả authorizers vào `Roles` module khi boot.

#### 3.5 Server GenServer (`lib/fz_http/server.ex`)

Bridge giữa fz_http và fz_vpn/fz_wall:

| Call | Hướng | Mục đích |
|---|---|---|
| `:load_peers` | http → vpn | Tải danh sách peers khởi động |
| `:load_settings` | http → wall | Tải users/devices/rules khởi động |
| `:update_device_stats` | vpn → http | Push stats WireGuard lên DB |

#### 3.6 VPN Session Logic

##### Config liên quan

| Field DB | Đơn vị | Default | Ý nghĩa |
|---|---|---|---|
| `vpn_session_duration` | giây (integer) | `0` | `0` = không bao giờ expire |
| `require_mfa` | boolean | `false` | Force MFA cho tất cả users |

`vpn_sessions_expire?()` trả về `true` khi `0 < duration < 2_147_483_647`.

---

##### Luồng khi user đăng nhập

**Trường hợp `require_mfa = false`:**
```
Nhập password thành công
  → Authentication.sign_in()
      → Users.update_last_signed_in()   ← last_signed_in_at = NOW()
      → Guardian token vào session
  → Redirect vào app
```

**Trường hợp `require_mfa = true`:**
```
Nhập password thành công
  → Authentication.sign_in()
      → update_last_signed_in() bị BỎ QUA  ← last_signed_in_at không đổi
      → Guardian token vào session
      → logged_in_at = NOW() (session key riêng)
  → LiveMFA hook kiểm tra: logged_in_at > mfa.last_used_at?
      YES → redirect /mfa/auth/:id
      NO  → cho vào app

Hoàn thành MFA verify (auth_live.ex):
  → MFA.use_method()                    ← cập nhật mfa.last_used_at
  → Users.update_last_signed_in()       ← last_signed_in_at = NOW() (lần này mới set)
  → Redirect vào app

Đăng ký MFA lần đầu (register_component.ex):
  → MFA.create_method()
  → Users.update_last_signed_in()       ← last_signed_in_at = NOW()
  → Redirect vào app
```

**Điểm mấu chốt:** `last_signed_in_at` chỉ được set sau khi hoàn thành MFA khi `require_mfa = true`. Đây là mốc duy nhất để VPN enforcement dùng.

---

##### `Device.Query.only_active/1` — quyết định peer nào được add vào WireGuard

```elixir
cond do
  # Case 1: Session có expiry
  vpn_sessions_expire?() ->
    if require_mfa do
      # nil = chưa làm MFA bao giờ → DENY
      not is_nil(last_signed_in_at)
        AND last_signed_in_at + duration > now()
    else
      # nil = chưa login bao giờ → ALLOW (behavior gốc)
      is_nil(last_signed_in_at)
        OR last_signed_in_at + duration > now()
    end

  # Case 2: Không có session expiry, nhưng require_mfa
  require_mfa ->
    not is_nil(last_signed_in_at)   # phải đã làm MFA ít nhất 1 lần

  # Case 3: Không có gì cả → tất cả active
  true ->
    true
end
```

Ngoài ra: `user.disabled_at IS NULL` luôn được check.

---

##### Ma trận hành vi VPN

| `require_mfa` | `vpn_session_duration` | `last_signed_in_at` | VPN active? |
|---|---|---|---|
| false | 0 | bất kỳ | ✅ Luôn active |
| false | > 0 | nil (chưa login) | ✅ Active (nil bypass) |
| false | > 0 | set, chưa hết hạn | ✅ Active |
| false | > 0 | set, đã hết hạn | ❌ Bị remove |
| **true** | **0** | **nil** | **❌ Blocked (chưa MFA)** |
| **true** | **0** | **set** | **✅ Active mãi mãi** |
| **true** | **> 0** | **nil** | **❌ Blocked** |
| **true** | **> 0** | **set, chưa hết hạn** | **✅ Active** |
| **true** | **> 0** | **set, đã hết hạn** | **❌ Bị remove → phải re-MFA** |

**Lưu ý:** Để mỗi lần re-login đều phải re-verify MFA mới có VPN, cần `vpn_session_duration > 0`. Với `vpn_session_duration = 0`, chỉ cần làm MFA 1 lần đầu, sau đó VPN active mãi.

---

##### VpnSessionScheduler (`lib/fz_http/vpn_session_scheduler.ex`)

```
Mỗi 60 giây:
  Events.set_config()
    → Devices.to_peer_list()
        → Device.Query.only_active()    ← lọc theo logic trên
    → FzVpn.Server.set_config(peer_list)
        → apply_config_diff(old, new)
            → xóa peer không còn trong new list
            → add peer mới trong new list
```

Tức là VPN peer bị add/remove trong vòng tối đa **60 giây** sau khi MFA hoàn thành hoặc session expire.

---

##### VPN Status trên UI (`vpn_status_component.ex`)

```elixir
cond do
  user.disabled_at                          → "Disabled"
  expired && user.last_signed_in_at         → "Expired" (session timeout)
  expired && is_nil(user.last_signed_in_at) → "Expired" (chưa MFA bao giờ)
  !expired                                  → "Enabled"
end
```

`vpn_session_expired?(user)`:
- `last_signed_in_at = nil` + `require_mfa = true` → `true` (hiện "Expired")
- `last_signed_in_at = nil` + `require_mfa = false` → `false` (hiện "Enabled")
- `vpn_sessions_expire? = false` → `false`
- Còn lại: so sánh `last_signed_in_at + duration` với `now()`

---

##### Device tạo bởi admin cho user chưa login

Khi admin tạo device cho user mới (`last_signed_in_at = nil`, `require_mfa = true`):
1. `Repo.insert` → PostgreSQL trigger `devices_changed` → `Repo.Notifier`
2. `Events.add("devices", device)` → `set_config(to_peer_list())`
3. `only_active()` → user.last_signed_in_at IS NULL → device **không vào peer list**
4. WireGuard peer **không được add** → VPN không kết nối được
5. Sau khi user đăng nhập và hoàn thành MFA → `last_signed_in_at = NOW()` → scheduler 60s tiếp theo add peer → VPN hoạt động

---

##### Bảo mật bổ sung — MFA method ownership check (`auth_live.ex`)

`handle_params` kiểm tra method thuộc về `current_user` trước khi load:
```elixir
with {:ok, method} <- MFA.fetch_method_by_id(id),
     true <- method.user_id == socket.assigns.current_user.id do
  ...
else
  _ -> {:halt, redirect(socket, to: ~p"/")}
end
```
Ngăn user dùng method UUID của user khác để bypass MFA challenge.

#### 3.7 Web Layer (`lib/fz_http_web/`)

**Router pipelines:**
```
:browser        ─► session + CSRF + LiveView flash
:api            ─► JSON, Bearer token auth, RequireMFA plug
:require_auth   ─► redirect to login if unauthenticated
:require_admin  ─► 403 if not admin role
```

**Live Views chính:**
| Live View | Path | Chức năng |
|---|---|---|
| `DeviceLive.Index` | `/devices` | List/add devices (admin view all, user view own) |
| `DeviceLive.Show` | `/devices/:id` | Chi tiết device, download WireGuard config |
| `UserLive.Index` | `/users` | User management (admin only) |
| `UserLive.Show` | `/users/:id` | User profile + devices |
| `RuleLive.Index` | `/rules` | Firewall rule management |
| `SettingLive.Account` | `/settings/account` | Email, password, MFA |
| `SettingLive.Security` | `/settings/security` | OIDC/SAML config |
| `SettingLive.Defaults` | `/settings/client` | Default WireGuard client config |
| `ConnectivityChecks` | `/settings/connectivity` | Internet connectivity status |

**Live Hooks:**
- `LiveAuth` — kiểm tra Guardian token, redirect nếu hết hạn
- `LiveMFA` — bắt buộc TOTP nếu user bật MFA; nếu Force MFA bật và user chưa enroll → redirect đến trang đăng ký (bỏ qua khi `live_action == :register_mfa`)
- `LiveNav` — set breadcrumbs, flash messages

**JSON API** (`/v0/`):
```
GET/POST   /v0/users
GET/PATCH  /v0/users/:id
GET/POST   /v0/devices
GET/PATCH  /v0/devices/:id
GET/POST   /v0/rules
GET/POST   /v0/configuration
```

**WireGuard config download** (`WireguardConfigView`):
- Render file `.conf` cho client
- Gồm: `[Interface]` (private key, addr, DNS) + `[Peer]` (server public key, endpoint, allowed_ips)

#### 3.8 Encryption

| Data | Encryption |
|---|---|
| Password | Argon2 hash |
| PSK, private key | Cloak AES-256-GCM (field-level) |
| OIDC tokens | Cloak AES-256-GCM |
| DB transport | TLS (configurable) |
| Cookie | Phoenix encrypted cookie |

#### 3.9 Database Migrations (40 migrations)

Trình tự tạo:
1. `users` — email, role, password_hash
2. `devices` — WireGuard peers, IP allocation
3. `rules` — egress firewall rules
4. `configurations` — system config
5. `oidc_connections` — linked IdP accounts
6. `mfa_methods` — TOTP secrets
7. `api_tokens` — REST API auth
8. `connectivity_checks` — Internet check logs
9. Index optimizations, UUID migrations, datetime fixes
10. `20260525000001` — add `require_mfa boolean NOT NULL DEFAULT false` to `configurations`

---

### `apps/fz_vpn` — WireGuard VPN Module

#### 3.10 Supervisor Tree

```
FzVpn.Application (one_for_one)
├── FzVpn.Server         (GenServer, name: :fz_vpn_server)
└── FzVpn.StatsPushService (GenServer)
```

#### 3.11 Adapter Pattern

```
config :fz_vpn, :wg_adapter, FzVpn.Interface.WgAdapter.Live    # production
config :fz_vpn, :wg_adapter, FzVpn.Interface.WgAdapter.Sandbox  # dev/test
```

**Live adapter** → delegates đến thư viện `Wireguardex` (NIF gọi kernel WireGuard API)
**Sandbox adapter** → GenServer lưu in-memory Map, dùng trong tests

#### 3.12 Keypair Management (`lib/fz_vpn/keypair.ex`)

```
Boot
 │
 ├── File /var/nexguard/private_key tồn tại?
 │     YES → đọc private key
 │     NO  → generate mới, lưu với chmod 0600
 │
 └── Derive public key qua Wireguardex.get_public_key/1
     Cache vào module attribute
```

#### 3.13 Server GenServer (`lib/fz_vpn/server.ex`)

**State:** map các peers hiện tại `%{public_key => peer_config}`

**Init sequence:**
1. Load/generate keypair
2. Setup WireGuard interface `wg-nexguard`
3. Gọi `:load_peers` trên fz_http server → nhận danh sách devices
4. Áp dụng peer config

**Key operations:**

```elixir
# Diff-based config update
def apply_config_diff(old_peers, new_peers) do
  # 1. Remove peers không còn trong new_peers
  # 2. Update peers thay đổi config
  # 3. Add peers mới
  # → Tối thiểu hóa WireGuard disruption
end

# Remove single peer (khi user delete device)
handle_call({:remove_peer, public_key}, ...)

# Full reconfiguration (khi settings thay đổi)
handle_call({:set_config, peers}, ...)
```

#### 3.14 Interface Module (`lib/fz_vpn/interface.ex`)

Wraps `WgAdapter` với:
- CIDR normalization cho allowed_ips
- Handshake timestamp formatting
- Error logging cho mỗi operation
- `dump/1` → trả về `%{public_key => %{rx_bytes, tx_bytes, latest_handshake, endpoint}}`

#### 3.15 Stats Push Service (`lib/fz_vpn/stats_push_service.ex`)

```
Mỗi 60 giây:
 Interface.dump("wg-nexguard")
    └─► FzHttp.Server.update_device_stats/1
           └─► UPDATE devices SET rx_bytes, tx_bytes, latest_handshake
```

---

### `apps/fz_wall` — nftables Firewall Module

#### 3.16 Supervisor Tree

```
FzWall.Application (one_for_one)
└── FzWall.Server (GenServer, name: :fz_wall_server)
```

#### 3.17 Adapter Pattern

```
config :fz_wall, :cli, FzWall.CLI.Live     # production
config :fz_wall, :cli, FzWall.CLI.Sandbox  # dev/test
```

**Sandbox** → tất cả operations trả về `""` (no-op), không chạy nft

#### 3.18 Server GenServer (`lib/fz_wall/server.ex`)

**State:**
```elixir
%{
  users:   MapSet.t(),   # user IDs
  devices: MapSet.t(),   # device structs
  rules:   MapSet.t()    # rule structs
}
```

**Init sequence:**
1. Gọi `cli().setup_firewall()` — xóa table cũ, tạo mới
2. Gọi `:load_settings` trên fz_http server
3. Gọi `cli().restore(settings)` — rebuild toàn bộ nftables state

**Operations (tất cả là synchronous GenServer calls):**

| Call | Hành động |
|---|---|
| `{:add_user, user_id}` | Tạo sets + chain + jump rules cho user |
| `{:delete_user, user_id}` | Xóa toàn bộ sets + chain của user |
| `{:add_device, device}` | Thêm device IP vào `user_ip_devices` set |
| `{:delete_device, device}` | Xóa device IP khỏi set |
| `{:add_rule, rule}` | Thêm destination vào accept/drop set |
| `{:delete_rule, rule}` | Xóa destination khỏi set |
| `{:set_rules, settings}` | Full restore (rebuild từ đầu) |

#### 3.19 CLI Live Adapter (`lib/fz_wall/cli/live.ex`)

**`setup_firewall/0`:**
```bash
# 1. Xóa bảng cũ nếu tồn tại (kiểm tra qua `nft list table inet nexguard`)
nft delete table inet nexguard

# 2. Tạo bảng mới
nft create table inet nexguard

# 3. Tạo chain forward (filter hook, priority 0, policy accept)
nft add chain inet nexguard forward { type filter hook forward priority 0 ; policy accept ; }

# 4. Tạo chain postrouting (nat hook, priority 100)
nft add chain inet nexguard postrouting { type nat hook postrouting priority 100 ; }

# 5. Setup masquerade: enumerate /sys/class/net/, bỏ qua "lo" và wg-nexguard
#    Với mỗi interface còn lại (vd: eth0):
nft add rule inet nexguard postrouting oifname eth0 meta nfproto ipv4 masquerade persistent
nft add rule inet nexguard postrouting oifname eth0 meta nfproto ipv6 masquerade persistent
# (chỉ thêm rule ipv4 nếu wireguard_ipv4_masquerade=true, tương tự ipv6)
```

**`add_user/1` — tạo đầy đủ sets + rules cho 1 user:**
```
1. Tạo device sets (type ipv4_addr / ipv6_addr, flags interval):
     user{uuid}_ip_devices, user{uuid}_ip6_devices

2. Tạo filter sets (tuỳ port_based_rules_supported config):
     IP-only:  user{uuid}_ip_drop, user{uuid}_ip_accept
               user{uuid}_ip6_drop, user{uuid}_ip6_accept
     L4:       user{uuid}_ip_drop_layer4, user{uuid}_ip_accept_layer4
               user{uuid}_ip6_drop_layer4, user{uuid}_ip6_accept_layer4
     (type: ipv4_addr / ipv6_addr . inet_proto . inet_service)

3. Tạo user chain (regular chain, không có hook):
     nft add chain inet nexguard user{uuid}

4. Thêm filter rules vào user chain (dùng insert_rule → rule mới đứng đầu):
   # Filter rules có thêm "meta iifname wg-nexguard" (chỉ áp dụng cho WG traffic)
   - ip6 daddr . meta l4proto . th dport @user{uuid}_ip6_accept_layer4 meta iifname wg-nexguard accept
   - ip6 daddr . meta l4proto . th dport @user{uuid}_ip6_drop_layer4   meta iifname wg-nexguard drop
   - ip6 daddr @user{uuid}_ip6_accept                                   meta iifname wg-nexguard accept
   - ip6 daddr @user{uuid}_ip6_drop                                     meta iifname wg-nexguard drop
   - ip  daddr . meta l4proto . th dport @user{uuid}_ip_accept_layer4  meta iifname wg-nexguard accept
   - ip  daddr . meta l4proto . th dport @user{uuid}_ip_drop_layer4    meta iifname wg-nexguard drop
   - ip  daddr @user{uuid}_ip_accept                                    meta iifname wg-nexguard accept
   - ip  daddr @user{uuid}_ip_drop                                      meta iifname wg-nexguard drop

5. Thêm jump rules vào chain forward:
   - ip  saddr @user{uuid}_ip_devices  jump user{uuid}
   - ip6 saddr @user{uuid}_ip6_devices jump user{uuid}
```

**`add_device/1`:**
```bash
# IP được normalize trước khi thêm (standardized_inet):
#   - CIDR: normalize qua CIDR.parse/1 (vd: 10.0.0.1/24 → 10.0.0.0/24)
#   - Single IP: parse qua :inet.parse_address → :inet.ntoa (chuẩn hóa format)
nft add element inet nexguard user{uuid}_ip_devices  { <ipv4_normalized> }
nft add element inet nexguard user{uuid}_ip6_devices { <ipv6_normalized> }
# Chỉ thêm element nếu device có IP tương ứng (bỏ qua nếu nil)
```

**`add_rule/1`:**
```bash
# Xác định ip_type từ rule.destination (IPv4 tuple size 4, IPv6 tuple size 8)
# Xác định set từ: ip_type × action × layer4

# Rule IP-only (port_type = nil):
nft add element inet nexguard user{uuid}_ip_accept { 10.0.0.0/8 }

# Rule với port (port_type = tcp/udp, port_range = "443"):
nft add element inet nexguard user{uuid}_ip_accept_layer4 { 10.0.0.0/8 . tcp . 443 }
```

**`delete_rule/1` — xóa rule khỏi set (giống add nhưng dùng delete element)**

**`delete_user/1` — cleanup theo thứ tự:**
```
1. delete_jump_rules (xóa các jump rule trong chain forward, dùng handle-based deletion)
2. delete_user_set   (xóa ip_devices sets)
3. delete_chain      (xóa chain user{uuid})
4. delete_filter_sets (xóa các accept/drop sets)
```

**Handle-based rule deletion (`delete_rule_matching`):**
```elixir
# Không thể xóa rule theo nội dung trực tiếp → phải tìm handle:
rules = exec!("nft -a list table inet nexguard")  # -a = show handles
# Regex scan để lấy handle number:
# /^\s*<rule_str>.*# handle (?<num>\d+)/m
# Sau đó xóa theo handle (re-scan mỗi lần vì handle thay đổi sau mỗi lần xóa)
exec!("nft delete rule inet nexguard forward handle <num>")
```

**`restore/1` — rebuild toàn bộ state (gọi khi boot):**
```
For each user_id in users:   add_user(user_id)
For each device in devices:  add_device(device)
For each rule in rules:      add_rule(rule)
```

#### 3.20 Set Naming Convention (`lib/fz_wall/cli/helpers/sets.ex`)

```
Device sets:
  user{uuid}_ip_devices        # IPv4 WireGuard IPs của user
  user{uuid}_ip6_devices       # IPv6 WireGuard IPs

Per-user filter sets:
  user{uuid}_ip_drop            # IPv4 drop destinations
  user{uuid}_ip_accept          # IPv4 accept destinations
  user{uuid}_ip_drop_layer4     # IPv4 drop với IP+proto+port
  user{uuid}_ip_accept_layer4   # IPv4 accept với IP+proto+port
  (tương tự ip6_*)

Global filter sets (user_id = nil):
  ip_drop, ip_accept
  ip_drop_layer4, ip_accept_layer4
  ip6_drop, ip6_accept
  ip6_drop_layer4, ip6_accept_layer4
```

#### 3.21 Shell Execution (`lib/fz_wall/shell.ex`)

```elixir
# Mọi lệnh nft đều chạy qua:
Shell.exec!("nft add rule ...")   # raises nếu exit_code != 0
Shell.exec("nft list ...")        # suppress errors, log warning
```

---

### 3.22 Luồng dữ liệu giữa 3 apps

```
User tạo Device qua Web UI
         │
         ▼
  fz_http.Devices.create_device()
         │
         ├──► INSERT INTO devices (ip allocation với advisory lock)
         │
         ├──► FzVpn.Server.set_config(new_peers)
         │         └──► WireGuard kernel: add peer
         │
         └──► FzWall.Server.add_device(device)
                   └──► nft add element ...ip_devices { device_ip }

User xóa Device
         │
         ├──► FzVpn.Server.remove_peer(public_key)
         │         └──► WireGuard kernel: remove peer
         │
         ├──► FzWall.Server.delete_device(device)
         │         └──► nft delete element ...
         │
         └──► DELETE FROM devices

Mỗi 60 giây (StatsPushService):
  FzVpn.Interface.dump("wg-nexguard")
         └──► FzHttp.Server.update_device_stats()
                   └──► UPDATE devices SET rx_bytes, tx_bytes, latest_handshake

System boot:
  fz_wall boots → fz_http.load_settings → restore nftables
  fz_vpn boots  → fz_http.load_peers   → configure WireGuard
```

---

## 4. Environment Variables (`.env`)

| Variable | Giá trị (production) | Mục đích |
|---|---|---|
| `VERSION` | `0.7.36` | App version |
| `EXTERNAL_URL` | `https://nexguard.binhphuong.io.vn` | Public URL cho Caddy + cookies |
| `DEFAULT_ADMIN_EMAIL` | `binhphuong.pcsr@gmail.com` | Admin account khởi tạo |
| `DEFAULT_ADMIN_PASSWORD` | *(set in .env)* | Admin password |
| `GUARDIAN_SECRET_KEY` | *(secret)* | JWT signing |
| `SECRET_KEY_BASE` | *(secret)* | Phoenix session encryption |
| `LIVE_VIEW_SIGNING_SALT` | *(secret)* | LiveView token |
| `COOKIE_SIGNING_SALT` | *(secret)* | Cookie signing |
| `COOKIE_ENCRYPTION_SALT` | *(secret)* | Cookie encryption |
| `DATABASE_ENCRYPTION_KEY` | *(secret)* | Cloak AES key cho DB |
| `DATABASE_PASSWORD` | *(secret)* | PostgreSQL password |
| `WIREGUARD_IPV4_NETWORK` | `10.0.55.0/24` | WireGuard IPv4 pool |
| `WIREGUARD_IPV4_ADDRESS` | `10.0.55.254` | WireGuard server IPv4 |
| `WIREGUARD_IPV6_NETWORK` | `fd00::/106` | WireGuard IPv6 pool |
| `WIREGUARD_IPV6_ADDRESS` | `fd00::1` | WireGuard server IPv6 |
| `TELEMETRY_ENABLED` | `false` | Tắt PostHog analytics |
| `TID` | `9e56556fe18c646b` | Telemetry ID |

---

## 5. Docker Compose — Production (`docker-compose.prod.yml`)

### Services

| Service | Image | Port | Network IP |
|---|---|---|---|
| `caddy` | `caddy:2` | 80, 443 (host network) | host |
| `nexguard` | `binhphuong/nexguard:0.7.40` | `51820/udp` (WireGuard) | `172.25.0.100` |
| `postgres` | `postgres:15` | internal | nexguard-network |

### Network `nexguard-network`
```
IPv4: 172.25.0.0/16
IPv6: fcff:3990:3990::/64  (gateway: fcff:3990:3990::1)
NexGuard IP: 172.25.0.100 / fcff:3990:3990::99
```

### Caddy Config (inline trong compose)
```
${EXTERNAL_URL} {
  log
  reverse_proxy * 172.25.0.100:13000
}
```

### NexGuard Container Capabilities
```yaml
cap_add:
  - NET_ADMIN    # WireGuard interface management
  - SYS_MODULE   # Kernel module loading
sysctls:
  net.ipv4.ip_forward: 1
  net.ipv6.conf.all.forwarding: 1
  net.ipv6.conf.all.disable_ipv6: 0
ulimits:
  nofile: 65536
```

### Restart Policy
```yaml
condition: unless-stopped
delay: 5s
window: 120s
update_config:
  order: start-first  # (stop-first cho postgres)
```

---

## 6. Docker Compose — Development (`docker-compose.yml`)

Thêm các service phụ cho dev:

| Service | Image | Mục đích |
|---|---|---|
| `caddy` | `caddy:2` | Reverse proxy |
| `nexguard` | built từ `Dockerfile.dev` | App server |
| `postgres` | `postgres:15` | Database |
| `vault` | `vault` (port 8200) | Secrets management |
| `saml-idp` | custom (port 8400/8443) | SAML test IdP |
| `client` | custom | WireGuard test client |

**Network dev:**
```
IPv4: 172.28.0.0/16
IPv6: fcff:3990:3990::/64
```

**Dev start script (`scripts/dev_start.sh`):**
```sh
ip link add dev wg-nexguard type wireguard
ip address replace dev wg-nexguard 100.64.0.1/10
ip -6 address replace dev wg-nexguard fd00::1/106
ip link set mtu 1280 up dev wg-nexguard
mix start
```

---

## 7. Dockerfile

### `Dockerfile.dev`
- Base: `nexguard/elixir:1.14.3-otp-25.2.1`
- Cài: yarn, build-base, git, python3, net-tools, iproute2, nftables, nodejs
- Compile Elixir deps + Node.js assets
- Tạo self-signed certs
- CMD: `/var/app/dev_start.sh`
- EXPOSE: `51820/udp`

### `Dockerfile.prod` (multi-stage)
- **Stage 1 (builder):** Compile Elixir release + Node.js assets
- **Stage 2 (runner):** Alpine với nftables, libstdc++, OpenSSL
- Artifact: mix release tại `/app`
- CMD: `/app/bin/server`

---

## 8. nftables Firewall Logic

> Source: `apps/fz_wall/lib/fz_wall/cli/live.ex`, `helpers/nft.ex`, `helpers/sets.ex`

### Cấu trúc tổng thể

```
table inet nexguard
├── chain forward       (filter hook, priority 0, policy accept)
│   ├── ip  saddr @user<UUID>_ip_devices  → jump user<UUID>   ← per-user jump (đứng đầu)
│   ├── ip6 saddr @user<UUID>_ip6_devices → jump user<UUID>
│   ├── ip6 daddr . proto . port @ip6_accept_layer4 → accept  ← global L4 rules
│   ├── ip6 daddr . proto . port @ip6_drop_layer4   → drop
│   ├── ip  daddr . proto . port @ip_accept_layer4  → accept
│   ├── ip  daddr . proto . port @ip_drop_layer4    → drop
│   ├── ip6 daddr @ip6_accept → accept                        ← global IP rules
│   ├── ip6 daddr @ip6_drop   → drop
│   ├── ip  daddr @ip_accept  → accept
│   └── ip  daddr @ip_drop    → drop
│
├── chain postrouting   (nat hook, priority 100)
│   └── oifname eth0 meta nfproto ipv4/ipv6 masquerade persistent
│
└── chain user<UUID>    (regular chain, per-user, không có hook)
    ├── ip6 daddr . proto . port @user<UUID>_ip6_accept_layer4 → accept
    ├── ip6 daddr . proto . port @user<UUID>_ip6_drop_layer4   → drop
    ├── ip  daddr . proto . port @user<UUID>_ip_accept_layer4  → accept
    ├── ip  daddr . proto . port @user<UUID>_ip_drop_layer4    → drop
    ├── ip6 daddr @user<UUID>_ip6_accept → accept
    ├── ip6 daddr @user<UUID>_ip6_drop   → drop
    ├── ip  daddr @user<UUID>_ip_accept  → accept
    └── ip  daddr @user<UUID>_ip_drop    → drop
        └── fall-through → quay lại chain forward → global rules
```

**Lưu ý thứ tự:** code dùng `insert rule` (prepend), nên rule insert **sau** đứng **trên**. L4 rules có ưu tiên cao hơn IP-only; accept có ưu tiên cao hơn drop trong cùng loại.

---

### Bước 1 — Boot: `setup_firewall()`

```bash
# Kiểm tra và xóa table cũ
nft list table inet nexguard          # exit 0 → tồn tại
nft delete table inet nexguard

# Tạo table mới
nft create table inet nexguard

# Tạo 2 base chains
nft 'add chain inet nexguard forward { type filter hook forward priority 0 ; policy accept ; }'
nft 'add chain inet nexguard postrouting { type nat hook postrouting priority 100 ; }'

# Masquerade — đọc /sys/class/net/, bỏ qua "lo" và "wg-nexguard"
# Với mỗi interface còn lại (vd eth0), nếu WIREGUARD_IPVx_MASQUERADE=true:
nft 'add rule inet nexguard postrouting oifname eth0 meta nfproto ipv4 masquerade persistent'
nft 'add rule inet nexguard postrouting oifname eth0 meta nfproto ipv6 masquerade persistent'
```

---

### Bước 2 — Boot tiếp: `setup_rules(nil)` — global sets + rules

```bash
# Global filter sets (IP-only, luôn tạo)
nft 'add set inet nexguard ip_drop    { type ipv4_addr ; flags interval ; }'
nft 'add set inet nexguard ip_accept  { type ipv4_addr ; flags interval ; }'
nft 'add set inet nexguard ip6_drop   { type ipv6_addr ; flags interval ; }'
nft 'add set inet nexguard ip6_accept { type ipv6_addr ; flags interval ; }'

# Global filter sets (L4 — chỉ tạo nếu port_based_rules_supported=true)
nft 'add set inet nexguard ip_drop_layer4    { type ipv4_addr . inet_proto . inet_service ; flags interval ; }'
nft 'add set inet nexguard ip_accept_layer4  { type ipv4_addr . inet_proto . inet_service ; flags interval ; }'
nft 'add set inet nexguard ip6_drop_layer4   { type ipv6_addr . inet_proto . inet_service ; flags interval ; }'
nft 'add set inet nexguard ip6_accept_layer4 { type ipv6_addr . inet_proto . inet_service ; flags interval ; }'

# Global filter rules — insert (prepend) vào chain forward
# Thứ tự insert: ip_drop → ip_accept → ip6_drop → ip6_accept → (layer4 tương tự)
# → rule insert cuối cùng đứng trên cùng sau khi xong
nft 'insert rule inet nexguard forward ip  daddr @ip_drop   meta iifname wg-nexguard drop'
nft 'insert rule inet nexguard forward ip  daddr @ip_accept meta iifname wg-nexguard accept'
nft 'insert rule inet nexguard forward ip6 daddr @ip6_drop   meta iifname wg-nexguard drop'
nft 'insert rule inet nexguard forward ip6 daddr @ip6_accept meta iifname wg-nexguard accept'
nft 'insert rule inet nexguard forward ip  daddr . meta l4proto . th dport @ip_drop_layer4   meta iifname wg-nexguard drop'
nft 'insert rule inet nexguard forward ip  daddr . meta l4proto . th dport @ip_accept_layer4 meta iifname wg-nexguard accept'
nft 'insert rule inet nexguard forward ip6 daddr . meta l4proto . th dport @ip6_drop_layer4   meta iifname wg-nexguard drop'
nft 'insert rule inet nexguard forward ip6 daddr . meta l4proto . th dport @ip6_accept_layer4 meta iifname wg-nexguard accept'
```

---

### Bước 3 — User được tạo: `add_user(user_id)`

```bash
# 1. Device sets (lưu WireGuard IPs của user)
nft 'add set inet nexguard user<UUID>_ip_devices  { type ipv4_addr ; flags interval ; }'
nft 'add set inet nexguard user<UUID>_ip6_devices { type ipv6_addr ; flags interval ; }'

# 2. Chain riêng cho user (regular, không hook)
nft 'add chain inet nexguard user<UUID>'

# 3. Jump rules vào chain forward (insert → đứng trước global rules)
nft 'insert rule inet nexguard forward ip  saddr @user<UUID>_ip_devices  jump user<UUID>'
nft 'insert rule inet nexguard forward ip6 saddr @user<UUID>_ip6_devices jump user<UUID>'

# 4. Per-user filter sets (giống global, prefix user<UUID>_)
nft 'add set inet nexguard user<UUID>_ip_drop    { type ipv4_addr ; flags interval ; }'
nft 'add set inet nexguard user<UUID>_ip_accept  { type ipv4_addr ; flags interval ; }'
nft 'add set inet nexguard user<UUID>_ip6_drop   { type ipv6_addr ; flags interval ; }'
nft 'add set inet nexguard user<UUID>_ip6_accept { type ipv6_addr ; flags interval ; }'
# + 4 layer4 sets nếu port_based_rules_supported=true (tương tự global)

# 5. Per-user filter rules — insert vào chain user<UUID>
nft 'insert rule inet nexguard user<UUID> ip  daddr @user<UUID>_ip_drop   meta iifname wg-nexguard drop'
nft 'insert rule inet nexguard user<UUID> ip  daddr @user<UUID>_ip_accept meta iifname wg-nexguard accept'
nft 'insert rule inet nexguard user<UUID> ip6 daddr @user<UUID>_ip6_drop   meta iifname wg-nexguard drop'
nft 'insert rule inet nexguard user<UUID> ip6 daddr @user<UUID>_ip6_accept meta iifname wg-nexguard accept'
# + 4 layer4 rules nếu enabled
```

---

### Bước 4 — Device được thêm: `add_device(device)`

```bash
# IP normalize trước: CIDR → CIDR.parse(), single IP → :inet.ntoa()
nft 'add element inet nexguard user<UUID>_ip_devices  { 10.0.55.x }'  # bỏ qua nếu nil
nft 'add element inet nexguard user<UUID>_ip6_devices { fd00::x }'    # bỏ qua nếu nil
```

---

### Bước 5 — Rule được tạo: `add_rule(rule)`

```bash
# Rule IP-only (port_type = nil):
nft 'add element inet nexguard user<UUID>_ip_accept { 10.0.0.0/8 }'    # user rule accept
nft 'add element inet nexguard ip_drop { 0.0.0.0/0 }'                  # global rule drop (user_id=nil)

# Rule có port (port_type = tcp/udp):
nft 'add element inet nexguard user<UUID>_ip_accept_layer4 { 10.0.235.0/24 . tcp . 443 }'
nft 'add element inet nexguard ip_accept_layer4 { 10.0.235.0/24 . tcp . 8000-9000 }'
```

---

### Bước 6 — Packet từ WireGuard client: luồng xử lý thực tế

```
Packet: 10.0.55.x → 10.0.0.1 (TCP 443)
         │
         ▼ chain forward
         ├─ ip saddr @user<UUID>_ip_devices → jump user<UUID>  ✓ MATCH
         │         │
         │         ▼ chain user<UUID>
         │         ├─ ip daddr . tcp . 443 @user<UUID>_ip_accept_layer4 → accept  ← nếu có rule này
         │         ├─ ip daddr . tcp . 443 @user<UUID>_ip_drop_layer4   → drop    ← hoặc rule này
         │         ├─ ip daddr @user<UUID>_ip_accept → accept  ← 10.0.0.0/8 → ACCEPT
         │         ├─ ip daddr @user<UUID>_ip_drop   → drop
         │         └─ fall-through → quay lại chain forward
         │
         ├─ (fall-through) ip6_accept_layer4, ip6_drop_layer4, ip_accept_layer4, ip_drop_layer4
         └─ (fall-through) ip6_accept, ip6_drop, ip_accept, ip_drop
```

---

### Bước 7 — Xóa device: `delete_device(device)`

```bash
nft 'delete element inet nexguard user<UUID>_ip_devices  { 10.0.55.x }'
nft 'delete element inet nexguard user<UUID>_ip6_devices { fd00::x }'
```

---

### Bước 8 — Xóa rule: `delete_rule(rule)`

```bash
nft 'delete element inet nexguard user<UUID>_ip_accept { 10.0.0.0/8 }'
# L4 rule:
nft 'delete element inet nexguard user<UUID>_ip_accept_layer4 { 10.0.235.0/24 . tcp . 443 }'
```

---

### Bước 9 — Xóa user: `delete_user(user_id)`

```bash
# 1. Xóa jump rules — phải tìm handle (không thể xóa theo nội dung)
nft -a list table inet nexguard
# regex: /^\s*ip saddr @user<UUID>_ip_devices jump user<UUID>.*# handle (\d+)/
nft delete rule inet nexguard forward handle <num>
# re-scan lại (handle tái đánh số sau mỗi lần xóa), xóa tiếp rule ip6

# 2. Xóa device sets
nft 'delete set inet nexguard user<UUID>_ip_devices'
nft 'delete set inet nexguard user<UUID>_ip6_devices'

# 3. Xóa chain (tự xóa luôn tất cả rules bên trong)
nft 'delete chain inet nexguard user<UUID>'

# 4. Xóa filter sets
nft 'delete set inet nexguard user<UUID>_ip_drop'
nft 'delete set inet nexguard user<UUID>_ip_accept'
nft 'delete set inet nexguard user<UUID>_ip6_drop'
nft 'delete set inet nexguard user<UUID>_ip6_accept'
# + 4 layer4 sets nếu enabled
```

---

### Điểm quan trọng

| Điểm | Chi tiết |
|---|---|
| `insert rule` = prepend | Rule insert **sau** đứng **trên** → thứ tự ưu tiên ngược với thứ tự code |
| Per-user jump rules | Luôn đứng **trước** global rules trong chain forward |
| `meta iifname wg-nexguard` | Có trong mọi filter rule → chỉ áp dụng cho WireGuard traffic |
| Handle-based deletion | `nft -a list` rồi regex lấy handle; re-scan sau mỗi lần xóa |
| IP normalization | CIDR: `CIDR.parse()` → chuẩn hóa; single IP: `:inet.ntoa()` |
| `port_based_rules_supported` | Config flag bật/tắt L4 sets — cần **kernel ≥ 5.6.9** (xem mục dưới); nếu tắt chỉ có 4 sets/user thay vì 8 |

---

### Yêu cầu kernel cho L4 sets (`port_based_rules_supported`)

L4 sets dùng nftables **concatenated sets với interval flag** — mỗi element là tuple 3 chiều `(IP, protocol, port)`:

```
type ipv4_addr . inet_proto . inet_service
flags interval
```

Định nghĩa thực tế tại `apps/fz_wall/lib/fz_wall/cli/helpers/nft.ex:256-260`:

```elixir
defp filter_set_type(:ip,  false), do: "ipv4_addr"
defp filter_set_type(:ip6, false), do: "ipv6_addr"
defp filter_set_type(ip_type, true),
  do: "#{filter_set_type(ip_type, false)} . inet_proto . inet_service"
```

Để lookup được tuple kiểu này, kernel cần engine **`nft_set_pipapo`** ("PIle PAcket POlicies").

| Kernel | Trạng thái |
|---|---|
| **< 5.6** | Không có `pipapo`. nftables chỉ match được set 1 chiều (chỉ IP, hoặc chỉ port). Không hỗ trợ tuple. |
| **5.6.0 – 5.6.8** | `pipapo` đã có nhưng lookup interval bị bug — tuple với port range silently mismatch hoặc crash. **Không production-ready.** |
| **≥ 5.6.9** | Stable kernel đầu tiên có đầy đủ fix interval-lookup của `pipapo` (backport từ Pablo Neira). L4 sets chạy đúng. |
| **≥ 5.10 LTS** | Khuyến nghị — đã merge thêm nhiều fix khác cho `pipapo`. |

**Fallback khi kernel cũ** (`port_based_rules_supported=false`):

- Chỉ tạo **4 sets/user** (IP-only) thay vì 8 — bỏ 4 sets `*_layer4`
- UI ẩn các field `port_type` / `port_range` khi tạo Rule (`apps/fz_http/lib/fz_http/rules/rule/changeset.ex:10-22`)
- Rule chỉ filter được theo IP/CIDR — không thể tách "cho phép 10.0.0.0/24:443" với "chặn 10.0.0.0/24 còn lại"
- 4 global rules `*_layer4` ở `forward` chain cũng không được tạo

Verify nhanh trên host:

```bash
uname -r                                     # ≥ 5.6.9?
nft list ruleset | grep -c inet_service      # >0 nếu L4 sets đang được tạo
```

**Reference**: Pablo Neira Ayuso, [*Pipapo: pile packet policies*](https://lwn.net/Articles/812060/), LWN 2020 — background về tại sao tuple lookup phức tạp hơn IP lookup và lý do `pipapo` cần fix riêng cho interval.

---

### Script `nft-firezone.sh` — NAT override thủ công (production)

Dùng khi cần forward không NAT cho các internal subnets:

```bash
# Rebuild chain postrouting với exception
nft delete chain inet nexguard postrouting
nft add chain inet nexguard postrouting { type nat hook postrouting priority srcnat; policy accept; }

# RETURN (không NAT) cho internal subnets — đặt TRƯỚC rule masquerade
nft add rule inet nexguard postrouting ip daddr 10.0.0.0/16 oifname "eth0" meta nfproto ipv4 return
nft add rule inet nexguard postrouting ip daddr 10.2.0.0/16 oifname "eth0" meta nfproto ipv4 return
nft add rule inet nexguard postrouting ip daddr 10.8.0.0/16 oifname "eth0" meta nfproto ipv4 return

# Masquerade tất cả còn lại
nft add rule inet nexguard postrouting oifname "eth0" meta nfproto ipv4 masquerade persistent
nft add rule inet nexguard postrouting oifname "eth0" meta nfproto ipv6 masquerade persistent
```

**MSS Clamping** (chống MTU fragmentation, chạy song song):
```bash
nft add table inet filter
nft add chain inet filter forward { type filter hook forward priority 0; policy accept; }
nft add rule inet filter forward tcp flags syn tcp option maxseg size set 1410
nft add rule inet filter output  tcp flags syn tcp option maxseg size set 1410
```

**Route thêm cho WireGuard subnet:**
```bash
ip route add 10.0.22.0/24 via 172.25.0.100 dev br-<bridge-id>
```

---

## 9. Ansible Deployment (`ansible/ansible/`)

### Playbook
```yaml
- name: Deploy ZeroTrust Stack
  hosts: all
  become: true
  roles:
    - network    # (main.yml tại roles/network/main.yml)
    - postgres
    - nexguard
    - caddy
```

### Variables (`group_vars/all.yml`)

| Var | Giá trị Ansible |
|---|---|
| `version` | `0.7.36` |
| `external_url` | `https://zerotrust.local.vn` |
| `wireguard_ipv4_network` | `10.0.22.0/24` |
| `wireguard_ipv4_address` | `10.0.22.254` |
| `fz_install_dir` | `/opt/nexguard` |

### Role: `postgres`
- Tạo dir `/opt/nexguard/postgres/data` (owner 999:999)
- Chạy `postgres:15` container trong `nexguard-network`
- Healthcheck: `pg_isready -U postgres` mỗi 30s

### Role: `nexguard`
1. Tạo dir `/opt/nexguard/nexguard`
2. Copy `.env` file (mode 0600)
3. Tạo Docker network `nexguard-network` (172.25.0.0/16 + fcff:3990:3990::/64)
4. Chạy container `binhphuong/nexguard:0.7.40`
   - Port: `51820/udp`, `13000`
   - IP: `172.25.0.100` / `fcff:3990:3990::99`
   - caps: NET_ADMIN, SYS_MODULE
5. Đợi container `running` (retry 10 lần × 3s)
6. Setup nftables trong container:
   - Xóa chain cũ → tạo lại
   - RETURN rules cho 10.0.0.0/16, 10.2.0.0/16, 10.8.0.0/16
   - Masquerade IPv4/IPv6 mặc định

### Role: `caddy`
1. Tạo dir `/opt/nexguard/caddy`
2. Copy SSL certs (`certificate.crt`, `private.key`)
3. Tạo Caddyfile:
   ```
   https://zerotrust.local.vn {
     log
     tls /data/caddy/certs/certificate.crt /data/caddy/certs/private.key
     reverse_proxy * 172.25.0.100:13000
   }
   ```
4. Chạy `caddy:2` với `network_mode: host`

---

## 10. Kubernetes Ingress (`k8s-ingress-zerotrust.yaml`)

```yaml
# Service trỏ đến NexGuard host (external endpoint)
Service: zerotrust (namespace: systems, port: 13000)
Endpoint: 10.0.235.9:13000

# Ingress
Host: zerotrust.sevensystem.vn
TLS: secret star-sevensystem-vn-tls
Ingress class: external-nginx
Proxy buffer: 32k × 8
Path: / → zerotrust:13000
```

---

## 11. WireGuard Configuration

### Interface `wg-nexguard`
```
IPv4: 10.0.55.254/24  (production .env)
       10.0.22.254/24  (ansible)
       100.64.0.1/10   (dev mode)
IPv6: fd00::1/106
MTU:  1280
```

### Peer Assignment
- Mỗi device được cấp 1 IP trong pool (10.0.55.x hoặc 10.0.22.x)
- IP được track qua `user<UUID>_ip_devices` set trong nftables
- Private key lưu tại `/var/nexguard/private_key`

### Post-up routing (`scripts/post-up-wg.sh`)
```bash
# Policy-based routing table 333444
ip rule add ...
ip route add ... table 333444
ip -6 rule add ...
ip -6 route add ... table 333444
```

---

## 12. CI/CD & GitHub Actions

| Workflow | File | Trigger |
|---|---|---|
| Docker build | `docker_build.yml` | PR / push |
| Docker publish | `docker_publish.yml` | Tag release |
| Omnibus build | `omnibus_build.yml` | PR / push |
| Omnibus publish | `omnibus_publish.yml` | Tag release |
| Tests | `test.yml` | PR / push |
| Static analysis | `static_analysis.yml` | PR / push |
| PR labeler | `pr_labeler.yml` | PR |

### Functional Test (`.ci/functional_test.sh`)
1. Install Omnibus package (RPM/DEB)
2. Disable telemetry + connectivity checks
3. Bootstrap config
4. Test: homepage load, WireGuard interface ops, firewall rules, telemetry ID

---

## 13. Code Quality

| Tool | Config | Scope |
|---|---|---|
| Credo | `.credo.exs` | Elixir linting (strict) |
| Dialyzer | `mix.exs` | Elixir type analysis |
| RuboCop | `.rubocop.yml` | Ruby scripts (Ruby 2.7) |
| codespell | `.codespellrc` | Spell check |
| markdownlint | `.markdownlint.json` | Markdown |
| mix format | `.formatter.exs` | Elixir formatting |
| pre-commit | `.pre-commit-config.yaml` | All hooks above |

**Pre-commit pipeline:**
```
mix-compile → mix-format → mix-lint (credo) → mix-analysis (dialyzer)
→ codespell → rubocop → yaml-check → trailing-whitespace
```

---

## 14. Debug / Live nftables State (`phuong-debug/`)

File debug chứa snapshot nftables thực tế đang chạy với:

**Global policies:**
- `ip_drop`: 0.0.0.0-255.255.255.255 (deny all by default)
- `ip_accept`: 10.5.67.0/24, 34.160.111.145
- `ip_accept_layer4`: NodePort ranges trên 10.0.235.0/24, port 443

**Active users và devices:**

| User UUID (prefix) | Devices (VPN IP) | Access |
|---|---|---|
| `19cf8e9a` | 100.96.60.28 | 10.0.0.0/8, 45.60.35.234 |
| `5b73cf06` | 100.65.0.100/101, 100.83.157.99, 100.127.72.72 | 0.0.0.0/0 (full tunnel) |
| `d3a392c5` | 100.93.6.154, 100.101.23.201 | 10.0.0.0/8 |
| `d3eec1ae` | 100.86.222.130, 100.95.227.109, ... (5 devices) | 10.0.0.0/8 |
| `637c90f5` | 100.70.53.180 | 45.60.35.234 + NodePorts |
| `f940c241` | 100.77.84.141, 100.93.96.147 | 45.60.35.234 + MongoDB 27017, NodePorts |
| `4258ea6c` | 100.64.164.154 | 45.60.35.234 |
| `d1ee4a53` | 100.100.245.232 | 45.60.35.234 |
| `204bf76f` | (no devices) | 45.60.35.234 |
| `d5e648bc` | (no devices) | (no rules) |
| `65fe3456` | (no devices) | (no rules) |

---

## 15. Tool Versions

```
nodejs  18.16.0
elixir  1.14.3-otp-25
erlang  25.2.1
ruby    2.7.6
python  3.9.13
```

---

## 16. Luồng triển khai nhanh

### Docker Compose (production Linux)
```bash
# 1. Clone repo + setup .env
cp .env.example .env && vim .env

# 2. Start stack
docker compose -f docker-compose.prod.yml up -d

# 3. Áp dụng nftables rules (nếu cần)
bash nft-firezone.sh

# 4. Thêm route cho WireGuard subnet
ip route add 10.0.22.0/24 via 172.25.0.100 dev <bridge>
```

### Ansible
```bash
cd ansible/ansible
ansible-playbook -i inventory playbook.yml
```

### Kubernetes
```bash
kubectl apply -f k8s-ingress-zerotrust.yaml
```

---

## 17. L7 ZTNA — Phase 1 (data + admin UI)

Landed in `v2.2.0`. Architectural decisions in `docs/decisions.md`
(ADR-007 → ADR-014); full proxy spec lives in
[`nexguard-connect/SPEC.md` §8](https://github.com/0xphuong/nexguard-connect/blob/main/SPEC.md#8-gateway-l7-architecture).
This section is the **server-side data model** that ships in `2.2.0`
— the proxy + CoreDNS + step-ca daemons land in later releases
(L7-B → L7-F).

### Tables

| Table | Role |
|---|---|
| `access_groups` | Manual / IdP-synced groups (`source ENUM('manual','idp_sync','system')`, `external_id` for SCIM reconciliation). |
| `user_group_memberships` | Composite-PK M:N with `source` provenance + `added_by_id` nilify. Immutable rows. |
| `applications` | `hostname` unique, `virtual_ip inet` unique inside `10.99.0.0/16`, `backend`, `cert_source ENUM('upload','step_ca')`, `cert_pem`, `key_pem` (`bytea`, encrypted via `FzHttp.Encrypted.Binary`), `tls_mode`, `l7_rules jsonb`, `enabled`. |
| `application_allowed_groups` | Composite-PK M:N — gate apps by group intersection. |
| `org_settings` | Singleton (CHECK `id = 1`) — `l7_enabled` kill switch, seeded by migration. |

Added to existing tables:

| Table | Column | Default | Purpose |
|---|---|---|---|
| `users` | `access_scope ENUM('limited','all')` | `'limited'` | Break-glass bypass at L7 (ADR-008). |

### Contexts

- `FzHttp.AccessGroups` — CRUD + members; bundle/identity-API readers.
- `FzHttp.Applications` — CRUD with in-transaction VIP allocation; M:N
  allowed-groups; PubSub `nexguard:l7:apps` per mutation.
- `FzHttp.OrgSettings` — singleton get/toggle + PubSub
  `nexguard:l7:settings`; no-op detection on identical writes.
- `FzHttp.L7.VipAllocator` — first-free scan inside `10.99.0.0/16`
  with advisory lock. Two entry points: own-transaction vs share
  caller's transaction so VIP pick + INSERT atomic.

### Authorizers

Admin-only; unprivileged sees nothing. All three registered in
`FzHttp.Auth.Roles.list_authorizers/0`:
`AccessGroups.Authorizer`, `Applications.Authorizer`,
`OrgSettings.Authorizer`.

### Admin surfaces (LiveView)

| Route | Purpose |
|---|---|
| `/access-groups` | List + stats strip + create + delete |
| `/access-groups/:id` | Edit, member roster, danger zone |
| `/users/:id` | + Group Memberships card + L7 Access Scope card |
| `/applications` | List + stats strip + delete |
| `/applications/new` + `/edit` | Form: name, hostname (RFC 1035), backend, cert source picker, conditional PEM textareas with inline X.509 preview |
| `/applications/:id` | Routing card, L7 Rules row editor (pill methods + reorder + implicit-deny), Allowed Groups picker, danger zone |
| `/settings/l7` | Org kill switch with status banner + confirmation modals |

### Two-level opt-in (ADR-014)

L7 enforcement requires **both** switches ON:

1. **Org-wide** `org_settings.l7_enabled` (toggled at `/settings/l7`).
2. **Per-app** `applications.enabled` (requires cert + ≥ 1 L7 rule).

Both flips are audited and broadcast on PubSub so the future proxy
can hot-reload its policy bundle.

### Routing (preview of L7-D)

```
Client DNS query
  ├─ hostname in declared apps     → CoreDNS returns VIP (10.99.0.0/16)
  └─ everything else (Google, etc) → upstream DNS → real public IP

Packet at gateway
  ├─ dst IP ∈ 10.99.0.0/16         → TPROXY → L7 proxy :8443
  └─ dst IP ∉ 10.99.0.0/16         → existing L3/L4 nftables forward
```

### PubSub topics (L7-B)

| Topic | Payload | Broadcast from | Subscribed by |
|---|---|---|---|
| `nexguard:l7:apps` | `:apps_changed` | `FzHttp.Applications.{create,update,delete,reorder_l7_rules,...}` | `BundleBuilder` |
| `nexguard:l7:settings` | `{:l7_enabled_changed, boolean}` | `FzHttp.OrgSettings.set_l7_enabled/3` (no-op writes do not broadcast) | `BundleBuilder`, future fz_wall TPROXY toggle |
| `nexguard:l7:groups` | `:groups_changed` | `FzHttp.AccessGroups.{create,update,delete}_group`, `{add,remove}_member` | `BundleBuilder` |
| `nexguard:l7:identity` | `{:identity_updated, vpn_ip_string}` | Fanned out by `FzHttp.L7.broadcast_identity_change/1` from `Users.update_user/4` (role change only), `Users.set_access_scope/4`, `AccessGroups.{add,remove}_member/4` | L7 proxy (invalidates per-VPN-IP identity cache) |
| `nexguard:l7:bundle` | `{:bundle_updated, version}` | `FzHttp.L7.BundleBuilder` after every successful compile + ETS write | L7 proxy (eager bundle refetch instead of polling) |

The three SOURCE topics (`apps`, `settings`, `groups`) feed
`BundleBuilder`, which debounces 300 ms then recompiles + signs the
bundle and emits a single `{:bundle_updated, v}` on the DOWNSTREAM
`nexguard:l7:bundle` topic.

`nexguard:l7:identity` is independent of the bundle flow — it
invalidates the proxy's 30 s `/internal/sessions/by_vpn_ip/:ip`
cache for one specific IP at a time, so a single user changing
groups doesn't force every proxy connection to refetch.

### L7-B HTTP endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/.well-known/jwks.json` | Public (RFC 8615) | Public RS256 keys for JWT verifiers. `Cache-Control: public, max-age=300` — matches grace window so a stale cache still verifies in-flight tokens |
| `GET` | `/internal/sessions/by_vpn_ip/:ip` | `:api_internal` (currently unauth; mTLS deferred to L7-D) | VPN-IP → identity payload. `Cache-Control: private, max-age=30` + weak ETag `W/"md5(user_id:user.updated_at)"`. 404 = `{"error":"unknown_vpn_ip"}` |
| `GET` | `/internal/bundle.json` | `:api_internal` | Latest signed policy bundle. `ETag: "v<N>"` + `X-NexGuard-Bundle-Signature: <jwt>`. `If-None-Match` → 304. `?since=N` → 304 if `bundle_version <= N` |

### Identity payload shape

`GET /internal/sessions/by_vpn_ip/:ip` returns JSON of the form
(produced by `FzHttp.L7.Identity.lookup_by_vpn_ip/1`):

```jsonc
{
  "user_id":         "<uuid>",
  "email":           "alice@example.com",
  "role":            "admin" | "unprivileged",
  "access_scope":    "limited" | "all",
  "groups":          ["devops", "oncall"],
  "device_id":       "<uuid>",
  "mfa_age_seconds": 142,    // null if user has no MFA method
  "signed_in_at":    "2026-06-21T08:49:11.820363Z"
}
```

`mfa_age_seconds` is `(now - users.last_signed_in_at)` only when the
user has at least one row in `mfa_methods`; otherwise nil so the
proxy doesn't read a password-only sign-in timestamp as MFA
freshness.

### Bundle JSON schema

`GET /internal/bundle.json` returns the body that
`FzHttp.L7.BundleBuilder` writes to ETS on each compile:

```jsonc
{
  "schema_version": 1,
  "bundle_version": 42,
  "compiled_at":    "2026-06-21T...Z",
  "org_settings":   { "l7_enabled": true },
  "jwks":           [ /* active + grace RS256 public JWKs */ ],
  "signing_key":    {
    "kid":         "<uuid matching one jwks entry>",
    "algorithm":   "RS256",
    "private_pem": "-----BEGIN RSA PRIVATE KEY-----\n..."
  },
  "apps": [
    {
      "id":                "<uuid>",
      "hostname":          "wiki.internal",
      "virtual_ip":        "10.99.0.5",
      "backend":           "wiki.svc.cluster.local:8080",
      "tls_mode":          "terminate" | "passthrough",
      "cert_source":       "upload" | "step_ca",
      "cert_pem":          "-----BEGIN CERTIFICATE-----\n...",
      "key_pem":           "-----BEGIN PRIVATE KEY-----\n...",
      "l7_rules":          [ /* admin-configured per-app rules */ ],
      "allowed_group_ids": ["<group-uuid>", ...],
      "inject_headers":    [],
      "strip_headers":     []
    }
  ],
  "groups": [
    { "id": "<uuid>", "name": "devops", "user_ids": ["<uuid>", ...] }
  ]
}
```

`bundle_version` is monotonic (`:ets.update_counter`). Both
`cert_pem` and `key_pem` ship in the bundle — `key_pem` is
Cloak-encrypted at rest but Ecto decrypts on load, and the L7
proxy needs the cleartext to terminate TLS for the app's SNI
cert. `inject_headers` / `strip_headers` are emitted as `[]`
until the `applications` schema gains those columns.

`signing_key.private_pem` is the **private** half of
`l7_signing_keys.private_pem`, decrypted in-process by
`FzHttp.L7.JwtSigner.active_signing_material/0`. The L7 proxy
(L7-D) uses it to sign `X-NexGuard-Identity-Jwt` on every request.
This makes the entire bundle response a secret-bearing artifact —
the same threat model as the per-app `cert_pem` entries — and is
the reason `/internal/bundle.json` is gated behind `:api_internal`.

---

## 18. Admin Dashboard

Module: `FzHttpWeb.DashboardLive.Index`
(`apps/fz_http/lib/fz_http_web/live/dashboard_live/`).

The dashboard is the admin's daily landing page, designed (Phase A,
v3.0.6) to answer **"is the system healthy right now?"** in a
single glance. It's NOT a navigation hub — the sidebar serves that.

### Zones

1. **Hero status banner** — aggregate severity across all alerts
   drives the banner colour. Empty alert list → green "All systems
   operational"; any alert flips it to info/warn/critical with the
   highest severity winning.
2. **Domain-grouped stat strip** — 4 click-through tiles
   (Identity / Network / L7 ZTNA / Activity), each carrying one
   headline metric + two semantic-dot sub-metrics.
3. **Recent activity feed** — last 8 entries from
   `AuditLogs.list_logs/1`, four-column grid.

(Zones 4-5: Security-checks panel rebuilt + Live VPN sessions →
Phase B.)

### Alert taxonomy

Each alert is a map `%{severity, icon, label, href}`. Severity
gradient (highest wins for the hero colour):

| Severity   | When |
|------------|------|
| `:critical`| Real outage / silent breakage (orphan-enabled apps, expired/<7d certs, service down) |
| `:warn`    | Security gap that won't break things today (low MFA, mixed-auth bypass, <30d cert) |
| `:info`    | Operational nudge (pending devices, stale devices, idle proxy, never-expire sessions) |

Active alert checks (`build_alerts/1`):

| Check | Trigger | Severity |
|-------|---------|----------|
| `pending_devices` | ≥1 device with `status=pending` | info |
| `cert_expired` | any cert past `not_after` | critical |
| `cert_critical` | cert expiring within 7d | critical |
| `cert_warn` | cert expiring within 30d (suppressed when critical also fires) | warn |
| `mfa_low_coverage` | enrolment <80% AND Force-MFA off | warn |
| `stale_devices` | >10 devices idle >30d | info |
| `service_health` | DB / proxy / CoreDNS `:down` or `:degraded` | critical |
| `l7_idle` | L7 enforcement ON but `enabled_apps == 0` | info |
| `orphan_enabled_apps` | app `enabled=true` AND `allowed_group_count == 0` (silently unreachable post-v3.0.5) | critical |
| `session_never_expires` | `vpn_session_duration == 0` | info |
| `mixed_auth_no_force_mfa` | local_auth + ≥1 SSO + Force-MFA OFF | warn |

### Data sources

| Surface | Reads from |
|---------|------------|
| Hero banner | `build_alerts/1` over all the below |
| Stat tile values | `Users.count/0`, `Devices.count_active_within/1`, `Applications.list_applications/1` (preloads `allowed_group_count`), `AccessGroups.list_groups/1`, `TlsCertificates.list_all_for_bundle/0`, `BundleBuilder.current/0` |
| Service health | `FzHttp.HealthMonitor.snapshot/0` (60s poll) |
| Recent activity | `AuditLogs.list_logs/1` (newest first, `Enum.take(8)`) |
| Config-driven alerts | `FzHttp.Config.fetch_config!/1` for `:require_mfa`, `:vpn_session_duration`, `:local_auth_enabled`, `:openid_connect_providers`, `:saml_identity_providers` |

### Defensive posture

`assign_all/1` MUST never raise. Every auxiliary call sits inside a
`safe_*` wrapper that rescues to a sane empty-state value:

  * `safe_l7_enabled?/0` → `false`
  * `safe_apps_list/1` → `[]`
  * `safe_group_count/1` → `0`
  * `safe_certs/0` → `[]`
  * `safe_bundle/0` → `nil`
  * `safe_health_snapshot/0` → all `:unknown`
  * `pending_device_count/0`, `audit_count_today/1` → `0`

A pre-bootstrap DB or a mid-restart supervisor surfaces as an
empty dashboard with the "all operational" banner — never a 500.
