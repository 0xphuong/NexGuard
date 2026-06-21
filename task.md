# Task list — NexGuard server

Last updated: 2026-06-19 · Server at **v2.1.1** · Pairs with NexGuard Connect **v0.0.9**

For the full feature history see [CHANGELOG.md](CHANGELOG.md). For the matching
client task list see [`nexguard-connect/task.md`](https://github.com/0xphuong/nexguard-connect/blob/main/task.md).

---

## ✅ Done — recent

The `2.x` line introduced native auth + admin features for the NexGuard
Connect client. Headline releases:

| Version | Highlights |
|---|---|
| **v2.1.1** (2026-06-19) | Admin notifications for pending device approvals — in-portal badge + Notifications page fire on enrollment, auto-clear on approve/revoke/delete |
| **v2.1.0** (2026-06-14) | Admin IP override (per-device IPv4/IPv6) + device approval workflow (`status: pending → approved`) |
| **v2.0.1** (2026-06-14) | MFA support for native client flow (reuses portal MFA challenge) |
| **v2.0.0** (2026-06-13) | Native auth (T1-T7): DB foundation, browser bridge, token endpoints, device enrollment, sign-out + revoke |
| **v1.3.x** | Stability + nftables port-range rules; final pre-2.x line |

---

## ⏳ Pending — ready to implement when prioritized

### 🚀 ZTNA L7 — Phase 2 (design locked, ready to start)

Layer 7 identity-aware access. L3/L4 enforcement is shipped (nftables
+ WG); L7 adds HTTP-method / path / header / MFA-age policy via a
TLS-terminating transparent proxy in front of managed apps. Full
architecture in [`docs/decisions.md`](docs/decisions.md) ADR-007 →
ADR-013 and [`nexguard-connect/SPEC.md` §8](https://github.com/0xphuong/nexguard-connect/blob/main/SPEC.md#8-gateway-l7-architecture).

**Locked design** (chốt 2026-06-19):
- **Scope**: L7 enforces **only on declared internal-domain apps**;
  public-internet traffic bypasses the proxy and stays on L4
  enforcement (ADR-014). Per-org `l7_enabled` toggle = kill switch.
- Proxy: custom Go binary (ADR-007)
- Policy language: inline JSONB rules, first-match, default deny; OPA Rego deferred (ADR-008)
- TLS: terminate by default; passthrough deferred to v2 (ADR-009)
- **Per-app cert source**: `upload` (admin's own cert, typical for
  real-DNS hostnames) OR `step_ca` (internal CA, typical for `.lan` /
  `.internal` hostnames). Both first-class (ADR-011 + ADR-014).
- Identity propagation: plain headers + RS256-signed JWT, IAP-style (ADR-010)
- Internal CA: smallstep `step-ca`, 90-day leaf certs via ACME — **deployed only when at least one declared app uses `cert_source: step_ca`** (ADR-011)
- DNS: CoreDNS hosts plugin, **selective override** — only declared
  hostnames; everything else passes through to upstream DNS (ADR-012)
- Policy distribution: Phoenix-pulled JSON bundle + PubSub invalidation (ADR-013)
- ext_authz gRPC interface: **document only**, not implemented in v1

| ID | Phase | Scope | Effort | Tag |
|---|---|---|---|---|
| **L7-A** | Foundation | DB schema (`access_groups`, `user_group_memberships`, `application_allowed_groups`, `applications.{hostname, virtual_ip, backend, cert_source, cert_pem, key_pem, l7_rules, enabled}`, `users.access_scope`, `org_settings.l7_enabled`); admin UI: groups + **per-app declaration form** (hostname, backend URL, cert source picker, upload-cert form, required groups, L7 rules editor); VIP allocator (10.99.0.0/16); per-org L7 toggle | 5-7 days | server `v2.2.0` |
| **L7-B** | Identity API + bundle | `/internal/sessions/by_vpn_ip/{ip}`, `/internal/bundle.json` (signed, mTLS) — includes only `enabled = true` apps; Phoenix.PubSub broadcasts (`:bundle_updated`, `:identity_updated`, `:l7_enabled_changed`) | 3-5 days | server `v2.3.0` |
| **L7-C** | Network plumbing | nftables TPROXY chain extending `fz_wall` (toggles on `org_settings.l7_enabled`); CoreDNS deploy with hosts plugin + reload; **selective hosts file** generated from declared apps only; non-declared queries forward upstream | 3-4 days | server `v2.4.0` |
| **L7-D** | L7 Proxy core | Custom Go binary: `IP_TRANSPARENT` listener, `SO_ORIGINAL_DST`, identity cache, group + rule eval, JWT-signed header inject, reverse proxy; **rejects unknown VIPs with 404 + `X-NexGuard-Reason: unknown-app`** | 7-10 days | server `v3.0.0` |
| **L7-E** | Operations | Hot-reload bundle (atomic swap + last-known-good fallback), audit log integration, branded deny / unknown-app pages, JWT signing key rotation, kill-switch handling | 2-3 days | server `v3.0.1` |
| **L7-F** | Internal CA (conditional) | smallstep `step-ca` sidecar, ACME automation, root + intermediate setup, leaf cert per app — **only deployed if any declared app sets `cert_source: step_ca`** | 3-4 days | server `v3.1.0` |
| **L7-G** | Client integration (conditional) | NexGuard Connect auto-installs internal CA root via `Security.framework` — **only invoked when the active server has `cert_source: step_ca` apps**; admin banner on install; MDM `.mobileconfig` template documented | 1-2 days | client `v0.1.0` |

**Total estimate**: ~3-5 weeks dev + ~1-2 weeks integration testing.

**Risks tracked** in [`docs/decisions.md`](docs/decisions.md):
TPROXY edge cases (asymmetric routing, IPv6) · smallstep CA outage ·
bundle compile latency at scale · browser cert trust UX · custom proxy
security bugs.

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

- [ ] **R-1**: routes — `/admin/access-groups`, `/admin/access-groups/:id`, `/admin/settings/l7`
- [ ] **R-2**: nav menu — "Access Groups" + "L7 Settings" entries in `admin.html.heex`
- [ ] **U-1**: `AccessGroupsLive.Index` — list (name, source, member count, created); "New Group" button
- [ ] **U-2**: `AccessGroupsLive.New` — form (name + description + source)
- [ ] **U-3**: `AccessGroupsLive.Show` — edit name/desc, member list with add/remove, list apps using this group
- [ ] **U-4**: empty state — "No groups yet — create one to start gating apps"
- [ ] **U-5**: delete confirm modal — warns "X apps reference this group"
- [ ] **U-6**: extend `UserLive.Show` — "Group Memberships" section with multi-select
- [ ] **U-7**: extend `UserLive.Show` — `access_scope` dropdown with warning text on 'all'
- [ ] **U-8**: extend `ApplicationLive.New/Edit` — add "L7 Settings" panel
- [ ] **U-9**: hostname field + RFC 1035 validation indicator
- [ ] **U-10**: backend URL field + validation
- [ ] **U-11**: cert source picker — radio "Upload" vs "Use NexGuard internal CA"
- [ ] **U-12**: cert upload form — textareas for `cert.pem` + `key.pem`; client-side preview cert subject + expiry
- [ ] **U-13**: required groups multi-select
- [ ] **U-14**: **L7 rules table editor** — add row (method multi-select, path_prefix, action, require_groups, require_mfa_age), reorder via drag, delete row
- [ ] **U-15**: TLS mode dropdown — 'terminate' default; 'passthrough' disabled with tooltip "Available in v2"
- [ ] **U-16**: enabled toggle — disabled until cert + hostname + ≥1 rule present
- [ ] **U-17**: `SettingsLive.L7` — org-level `l7_enabled` toggle
- [ ] **U-18**: pre-toggle warning — "Enabling L7 starts CoreDNS + Proxy services. Read L7-Architecture before flipping."
- [ ] **U-19**: post-enable banner — "L7 is now active. X declared apps will route through proxy."
- [ ] **T-5**: LiveView tests — `access_groups_live_test.exs` (mount, list, create, delete confirm)
- [ ] **T-6**: LiveView tests — `application_live_l7_test.exs` (form validation, cert preview, rules editor)
- [ ] **T-7**: LiveView tests — `settings_live_l7_test.exs` (toggle works)
- [ ] **T-8**: LiveView tests — `user_live_groups_test.exs` (membership assignment)

##### Phase 4 — Polish + docs (~0.5 day)

- [ ] **P-1**: update `NEXGUARD_LOGIC.md` with new L7 §: tables, relationships, lifecycle
- [ ] **P-2**: migration runbook — `docs/migrations/v2.2.0.md` — order, downtime (none expected — additive only), rollback procedure
- [ ] **P-3**: `CHANGELOG.md` entry — `[2.2.0] - 2026-06-XX` — L7-A scope
- [ ] **P-4**: update Obsidian — `Nexguard-Logic.md` add L7 schema; `Roadmap.md` move L7-A from Planned → Done after release
- [ ] **P-5**: `git tag v2.2.0` + push + update `nexguard-releases/versions.json`

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

### 🟡 Medium effort, valuable

| ID | Task | Effort | Notes |
|---|---|---|---|
| S5 | **Admin "Force re-auth" policy** (org-level setting "user must sign in again after X days") | ~2h server + ~1h client | Extra session control beyond the 24h VPN session. Per-org configurable. Server stamps `last_signed_in_at`; client checks on every refresh. |
| S6 | **Bulk device approve/revoke** (checkbox-select multiple) | ~2h | Admin convenience when onboarding a team. Currently each device is one-at-a-time. |
| S7 | **Audit log search + filter UI** | ~2-3h | Filter by actor / target / action / date range. Currently the audit log is a flat scrollable list. Admin oversight + compliance use case. |
| S8 | **API documentation** (OpenAPI / Swagger for `/api/v0/`) | ~2-3h | Enable third-party integration. Auto-generated from controller annotations would be lowest-maintenance. |

### 🔵 Larger features

| ID | Task | Effort | Notes |
|---|---|---|---|
| S9 | **Compliance pre-flight** (FileVault / OS version / firewall check before connect) | ~3h server + ~3h client | Enterprise requirement. Server-side policy schema ("require macOS >= 14, FileVault on") + client-side check + report on Connect. |
| S10 | **Custom branding from server** (logo + accent color per org) | ~3h + server config endpoint | Per-org identity if NexGuard ever sells as SaaS. Client fetches `GET /config/branding` on bootstrap, caches locally. |
| S11 | **MDM profile support** (`.mobileconfig` template + docs) | ~3-4h client + server docs | Corporate distribution via Jamf / Intune. Allows IT to push server URL + restrictions automatically. |
| S12 | **Webhook system** for org events (device pending, user signed in, MFA challenge, approval changes) | ~3-4h | External integration target. Per-org webhook URL + event filter + retry/backoff. Generalizes S1. |

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
