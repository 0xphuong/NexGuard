defmodule FzWall.CLI.Helpers.Tproxy do
  @moduledoc """
  Helpers for the L7 ZTNA transparent-proxy redirection (ADR-007,
  ADR-014). Used only when the org-level `l7_enabled` toggle is on.

  Two ingredients land on the host:

    1. A dedicated nftables chain `l7_prerouting` hooked at the
       `prerouting` chain with priority `mangle` (-150). Packets
       arriving on the WireGuard interface destined for any IP in
       `10.99.0.0/16` (the VIP range carved for declared L7 apps)
       on TCP ports 80 or 443 get `meta mark set 0x1` and
       `tproxy to 127.0.0.1:8443` — handed off to the L7 proxy
       (L7-D, ships in a later release).

    2. A routing-table tweak so any packet with `fwmark 0x1` is
       routed via the local loopback table. This is what lets the
       L7 proxy receive the connection with `IP_TRANSPARENT` and
       recover the original destination via `SO_ORIGINAL_DST`.

  Both pieces are idempotent: install + uninstall checks current
  state and is safe to call repeatedly. The chain install is
  gated on `org_settings.l7_enabled`; the routing tweak is
  installed once at fz_wall boot regardless, because it's
  zero-cost when no marked packets exist.
  """
  import FzWall.Shell
  require Logger

  @table "nexguard"
  @chain "l7_prerouting"
  @vip_cidr "10.99.0.0/16"
  @proxy_addr "127.0.0.1:8443"
  @fwmark "0x1"
  @route_table "100"

  # ── L7 nftables chain ──────────────────────────────────────────

  @doc """
  Install the L7 prerouting chain + rule. Safe to call when already
  installed (no-op).
  """
  def install_l7_chain do
    if chain_exists?() do
      :ok
    else
      exec!(
        "#{nft()} 'add chain inet #{@table} #{@chain} " <>
          "{ type filter hook prerouting priority mangle ; policy accept ; }'"
      )

      exec!(
        "#{nft()} 'add rule inet #{@table} #{@chain} " <>
          "meta iifname #{wireguard_interface_name()} " <>
          "ip daddr #{@vip_cidr} tcp dport { 80, 443 } " <>
          "meta mark set #{@fwmark} tproxy to #{@proxy_addr} accept'"
      )

      Logger.info("[L7] installed nftables TPROXY chain '#{@chain}'")
      :ok
    end
  end

  @doc """
  Remove the L7 prerouting chain. Safe to call when already absent.
  """
  def remove_l7_chain do
    if chain_exists?() do
      # `delete chain` requires the chain to be empty in older nft
      # versions — flush first to be safe across kernels.
      exec("#{nft()} flush chain inet #{@table} #{@chain}", suppress: true)
      exec!("#{nft()} 'delete chain inet #{@table} #{@chain}'")
      Logger.info("[L7] removed nftables TPROXY chain '#{@chain}'")
      :ok
    else
      :ok
    end
  end

  defp chain_exists? do
    case bash("#{nft()} list chain inet #{@table} #{@chain}") do
      {_, 0} -> true
      _ -> false
    end
  end

  # ── ip route + ip rule for fwmark ──────────────────────────────

  @doc """
  Set up the loopback routing table + fwmark rule required for the
  TPROXY socket to receive marked packets. Idempotent.
  """
  def install_fwmark_route do
    unless route_exists?() do
      exec!("#{ip_cmd()} route add local 0.0.0.0/0 dev lo table #{@route_table}")
      Logger.info("[L7] added fwmark route to table #{@route_table}")
    end

    unless rule_exists?() do
      exec!("#{ip_cmd()} rule add fwmark #{@fwmark} lookup #{@route_table}")
      Logger.info("[L7] added fwmark #{@fwmark} → table #{@route_table} rule")
    end

    :ok
  end

  defp route_exists? do
    case bash("#{ip_cmd()} route show table #{@route_table}") do
      {out, 0} -> String.contains?(out, "local 0.0.0.0/0 dev lo")
      _ -> false
    end
  end

  defp rule_exists? do
    case bash("#{ip_cmd()} rule show") do
      {out, 0} -> String.contains?(out, "fwmark #{@fwmark} lookup #{@route_table}")
      _ -> false
    end
  end

  # ── Configurables ──────────────────────────────────────────────

  defp nft, do: Application.fetch_env!(:fz_wall, :nft_path)

  defp ip_cmd, do: Application.get_env(:fz_wall, :ip_path, "/sbin/ip")

  defp wireguard_interface_name,
    do: Application.fetch_env!(:fz_wall, :wireguard_interface_name)
end
