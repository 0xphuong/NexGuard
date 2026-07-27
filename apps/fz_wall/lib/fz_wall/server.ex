defmodule FzWall.Server do
  @moduledoc """
  Functions for applying firewall rules.
  """
  use GenServer
  import FzWall.CLI
  require Logger

  alias Phoenix.PubSub

  @init_timeout 1_000
  # L7 ZTNA — subscribed at boot. The fz_http side already publishes
  # `{:l7_enabled_changed, bool}` via `FzHttp.OrgSettings.set_l7_enabled/3`.
  @l7_settings_topic "nexguard:l7:settings"

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: {:global, :fz_wall_server})
  end

  @impl GenServer
  def init(_rules) do
    cli().setup_firewall()
    {:ok, settings} = GenServer.call(http_pid(), :load_settings, @init_timeout)
    cli().restore(settings)

    # L7 ZTNA plumbing (ADR-007). The fwmark route is installed once
    # regardless of the toggle — zero cost when no marked packets
    # flow. The TPROXY chain itself follows `l7_enabled`.
    #
    # CRITICAL: nft errors here must NOT crash the GenServer.
    # fz_wall.Server crashing repeatedly takes down the whole BEAM
    # (see v3.0.0 deploy bug — bad `tproxy to` syntax crash-looped
    # the node). L7 plumbing is opt-in; if it fails to install, we
    # log loudly + keep running so the base L3/L4 firewall stays up
    # and the operator can flip `l7_enabled` off to recover.
    try_l7(&cli().setup_fwmark_route/0, "fwmark route")

    if l7_enabled?() do
      try_l7(&cli().install_l7/0, "TPROXY chain")
    end

    PubSub.subscribe(FzHttp.PubSub, @l7_settings_topic)

    {:ok, settings}
  end

  @impl GenServer
  def handle_info({:l7_enabled_changed, true}, state) do
    Logger.info("[fz_wall] :l7_enabled_changed → true; installing TPROXY chain")
    try_l7(&cli().install_l7/0, "TPROXY chain")
    {:noreply, state}
  end

  def handle_info({:l7_enabled_changed, false}, state) do
    Logger.info("[fz_wall] :l7_enabled_changed → false; removing TPROXY chain")
    try_l7(&cli().remove_l7/0, "TPROXY chain removal")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp l7_enabled? do
    # Wrapped in try/rescue so a missing org_settings row (unlikely;
    # migration seeds it) doesn't prevent fz_wall from booting.
    FzHttp.OrgSettings.l7_enabled?()
  rescue
    e ->
      Logger.warning("[fz_wall] OrgSettings.l7_enabled?/0 raised: #{inspect(e)}")
      false
  end

  # Wrap any L7 nft / ip shell-out so a failure does NOT propagate
  # to the supervisor — fz_wall going down crashes the whole BEAM,
  # which is far worse than L7 just being silently inactive.
  defp try_l7(fun, what) do
    fun.()
  rescue
    e ->
      Logger.error(
        "[fz_wall][L7] #{what} install failed; L7 will be inactive until next boot. " <>
          "Error: #{Exception.message(e)}"
      )
      :error
  end

  @impl GenServer
  def handle_call({:add_rule, rule}, _from, %{rules: existing_rules} = state) do
    new_rules = add_rule(rule, existing_rules)

    {:reply, :ok, %{state | rules: new_rules}}
  end

  @impl GenServer
  def handle_call({:delete_rule, rule}, _from, %{rules: existing_rules} = state) do
    new_rules = delete_rule(rule, existing_rules)

    {:reply, :ok, %{state | rules: new_rules}}
  end

  @impl GenServer
  def handle_call({:add_device, device}, _from, %{devices: existing_devices} = state) do
    new_devices = add_device(device, existing_devices)

    {:reply, :ok, %{state | devices: new_devices}}
  end

  @impl GenServer
  def handle_call({:delete_device, device}, _from, %{devices: existing_devices} = state) do
    new_devices = delete_device(device, existing_devices)

    {:reply, :ok, %{state | devices: new_devices}}
  end

  @impl GenServer
  def handle_call({:set_rules, settings}, _from, _settings) do
    # v3.3.0: teardown + rebuild the whole `inet nexguard` table
    # before restore. `restore/1` in `FzWall.CLI.Live` is
    # additive -- it calls `add_user` / `add_device` / `add_rule`
    # without checking for existing state. Calling `set_rules`
    # more than once (which the Policies context now does on
    # every CRUD, so users see policy changes immediately without
    # a server restart) would otherwise pile duplicate jump rules
    # onto the forward chain + duplicate accept/drop rules onto
    # each per-user chain (each observed at ~5x on the staging
    # box after a handful of policy edits).
    #
    # `setup_firewall/0` runs `teardown_table + setup_table +
    # setup_chains + setup_rules(nil)` -- a clean slate, then
    # restore layers the current DB state on top. O(users x
    # rules) per call which stays sub-second on realistic org
    # sizes.
    cli().setup_firewall()
    cli().restore(settings)

    {:reply, :ok, settings}
  end

  @impl GenServer
  def handle_call(:reload_masquerade, _from, state) do
    cli().reload_postrouting()
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:add_user, user_id}, _from, %{users: existing_users} = state) do
    new_users = add_user(user_id, existing_users)

    {:reply, :ok, %{state | users: new_users}}
  end

  @impl GenServer
  def handle_call({:delete_user, user_id}, _from, %{users: existing_users} = state) do
    new_users = delete_user(user_id, existing_users)

    {:reply, :ok, %{state | users: new_users}}
  end

  def reload_masquerade do
    GenServer.call({:global, :fz_wall_server}, :reload_masquerade)
  end

  def http_pid do
    :global.whereis_name(:fz_http_server)
  end

  defp add_rule(rule, existing_rules) do
    cli().add_rule(rule)

    MapSet.put(existing_rules, rule)
  end

  defp delete_rule(rule, existing_rules) do
    cli().delete_rule(rule)

    MapSet.delete(existing_rules, rule)
  end

  defp add_user(user_id, existing_users) do
    cli().add_user(user_id)

    MapSet.put(existing_users, user_id)
  end

  defp delete_user(user_id, existing_users) do
    cli().delete_user(user_id)

    MapSet.delete(existing_users, user_id)
  end

  defp add_device(device, existing_devices) do
    cli().add_device(device)

    MapSet.put(existing_devices, device)
  end

  defp delete_device(device, existing_devices) do
    cli().delete_device(device)

    MapSet.delete(existing_devices, device)
  end
end
