defmodule FzWall.CLI.Sandbox do
  @moduledoc """
  Dummy module for working with nftables.
  """

  @default_returned ""

  def setup_firewall, do: @default_returned
  def emit_rule(_rule_spec), do: @default_returned
  def restore(_fz_http_rules), do: @default_returned
  def add_device(_device), do: @default_returned
  def delete_device(_device), do: @default_returned
  def add_user(_user), do: @default_returned
  def delete_user(_user), do: @default_returned

  # L7 ZTNA TPROXY (ADR-007). Sandbox stubs — real shell-outs live
  # in `FzWall.CLI.Live` and are exercised only on Linux production.
  def install_l7, do: @default_returned
  def remove_l7, do: @default_returned
  def setup_fwmark_route, do: @default_returned
end
