defmodule FzWall.CLI.Live do
  @moduledoc """
  A low-level module for interacting with the nftables CLI.

  Rules operate on the nftables forward chain to deny outgoing packets to
  specified IP addresses, ports, and protocols from NexGuard device IPs.

  v4.1.0: rule filter is CHAIN-BASED (was set-based). Each policy_rule
  emits a dedicated nftables chain rule in priority-ASC order, so
  admins can explicitly resolve overlap conflicts ("drop 8.8.4.4
  priority=10 wins over allow 8.8.0.0/16 priority=100"). The
  `_ip_devices` set is retained for source-IP lookups; only the
  filter sets (`_ip_accept`, `_ip_drop` and layer4 variants) went
  away.
  """
  import FzWall.CLI.Helpers.Sets
  import FzWall.CLI.Helpers.Nft
  import FzWall.CLI.Helpers.Tproxy, only: [install_l7_chain: 0, remove_l7_chain: 0, install_fwmark_route: 0]

  # ── L7 ZTNA TPROXY chain (ADR-007) ─────────────────────────────

  @doc "Install the L7 prerouting chain when `l7_enabled` flips on."
  def install_l7, do: install_l7_chain()

  @doc "Remove the L7 prerouting chain when `l7_enabled` flips off."
  def remove_l7, do: remove_l7_chain()

  @doc """
  Reload the postrouting chain — called by `FzWall.Server` after the
  admin updates `gateway_no_masquerade_enabled` or `_cidrs` via the
  /settings/network UI. Without this delegate the server crashed
  with `UndefinedFunctionError: FzWall.CLI.Live.reload_postrouting/0`
  because the helper was imported (callable inside this module) but
  never publicly exposed.
  """
  defdelegate reload_postrouting, to: FzWall.CLI.Helpers.Nft

  @doc """
  Set up the loopback table + fwmark rule. Called once at fz_wall
  boot — zero-cost when no marked packets flow.
  """
  def setup_fwmark_route, do: install_fwmark_route()

  @doc """
  Bootstrap the `inet nexguard` table with empty chains (forward +
  postrouting + masquerade). v4.1.0: no longer creates global
  filter sets -- policy rules land as chain rules via
  `emit_rule/1` during `restore/1`.
  """
  def setup_firewall do
    teardown_table()
    setup_table()
    setup_chains()
  end

  @doc """
  Create the per-user chain + device source-set + jump rule from
  forward. v4.1.0: no per-user filter sets -- policy rules go
  straight into the user chain via `emit_rule/1`.
  """
  def add_user(user_id) do
    add_user_set(user_id)
    add_chain(get_user_chain(user_id))
    set_jump_rule(user_id)
  end

  defp add_user_set(user_id) do
    list_dev_sets(user_id)
    |> Enum.map(fn set_spec -> add_dev_set(set_spec.name, set_spec.ip_type) end)
  end

  defp delete_user_set(user_id) do
    list_dev_sets(user_id)
    |> Enum.map(fn set_spec -> delete_set(set_spec.name) end)
  end

  @doc """
  Tear down the per-user chain + device source-set + jump rule.
  """
  def delete_user(user_id) do
    delete_jump_rules(user_id)
    delete_user_set(user_id)
    delete_chain(get_user_chain(user_id))
  end

  def set_jump_rule(user_id) do
    list_dev_sets(user_id)
    |> Enum.each(fn set_spec ->
      insert_dev_rule(set_spec.ip_type, set_spec.name, get_user_chain(user_id))
    end)
  end

  @doc """
  Adds device ip(s) to the user's sets, omitting missing IPs.
  """
  def add_device(device) do
    list_dev_sets(device.user_id)
    |> Enum.filter(fn set_spec ->
      device[set_spec.ip_type]
    end)
    |> Enum.each(fn set_spec ->
      add_elem(set_spec.name, device[set_spec.ip_type])
    end)
  end

  @doc """
  Eliminates device rules from its corresponding sets.
  """
  def delete_device(device) do
    get_ip_types()
    |> Enum.each(fn type -> remove_from_set(device.user_id, device[type], type) end)
  end

  defp remove_from_set(_user_id, nil, _type), do: :no_ip

  defp remove_from_set(user_id, ip, type) do
    get_device_set_name(user_id, type)
    |> delete_elem(ip)
  end

  defp delete_jump_rules(user_id) do
    list_dev_sets(user_id)
    |> Enum.each(fn set_spec ->
      remove_dev_rule(set_spec.ip_type, set_spec.name, get_user_chain(user_id))
    end)
  end

  @doc """
  Rebuild the whole nftables state from a snapshot. `rules` is a
  LIST (v4.1.0) sorted by priority ASC then inserted_at ASC, so
  the emission order below matches the intended evaluation order.

  Emission phases:
    1. `add_user/1` for every user -- creates chains + jump rules
       from forward. User jumps end up at forward's TOP because
       `insert_dev_rule/3` uses `nft insert rule` (prepend).
    2. `add_device/1` for every device -- populates the `_ip_devices`
       set that gates each user jump.
    3. `emit_rule/1` for every rule in priority order -- appends
       to either the user's chain (user_id!=nil) or forward
       (user_id==nil, global policy). Because global rules append
       AFTER add_user has already prepended user jumps, forward's
       final layout is:
             [user jumps] -> [global rules by priority] -> fallthrough
       Per-user rules land inside their chain and evaluate before
       returning to forward, so per-user policies always win over
       global fallbacks -- which matches admin intuition ("this
       team gets an exception").
  """
  def restore(%{users: users, devices: devices, rules: rules}) do
    Enum.each(users, &add_user/1)
    Enum.each(devices, &add_device/1)
    Enum.each(rules, &emit_rule/1)
  end

  def proto(inet_str) do
    case FzHttp.Types.INET.cast(inet_str) do
      {:ok, %{address: address}} when tuple_size(address) == 4 -> :ip
      {:ok, %{address: address}} when tuple_size(address) == 8 -> :ip6
    end
  end

  @doc """
  Emit one policy_rule as an nftables chain rule.

  For rules without `port_type`: `ip[6] daddr <cidr> <action>`.
  For rules with `port_type`: `ip[6] daddr <cidr> <proto> dport <port|range> <action>`.

  Falls into either `forward` (global rules, user_id=nil) or the
  per-user chain (`user<UUID>`).
  """
  def emit_rule(rule) do
    ip_family = proto(rule.destination)
    daddr_kw = to_string(ip_family)
    chain = get_user_chain(rule.user_id)

    port_match =
      case rule.port_type do
        nil ->
          ""

        proto ->
          case FzHttp.Types.Int4Range.cast(rule.port_range) do
            {:ok, port_str} -> " #{proto} dport #{port_str}"
            _ -> ""
          end
      end

    rule_str =
      "#{daddr_kw} daddr #{rule.destination}#{port_match} #{rule.action}"

    add_chain_rule(chain, rule_str)
  end
end
