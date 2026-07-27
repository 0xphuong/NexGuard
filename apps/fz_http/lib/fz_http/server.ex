defmodule FzHttp.Server do
  @moduledoc """
  Functions for other processes to interact with the FzHttp application
  """
  use GenServer
  alias FzHttp.{Devices, Devices.StatsUpdater, Policies, Rules, Users}

  def start_link(_) do
    # We're not storing state, simply providing an API
    GenServer.start_link(__MODULE__, nil, name: {:global, :fz_http_server})
  end

  @impl GenServer
  def init(state) do
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:load_peers, _from, state) do
    reply = {:ok, Devices.to_peer_list()}
    {:reply, reply, state}
  end

  @impl GenServer
  def handle_call(:load_settings, _from, state) do
    # v3.3.0: `fz_wall`'s boot path (`FzWall.Server.init`) calls
    # `:load_settings` on this process to seed nftables. Same
    # union as `FzHttp.Events.set_rules/0` -- policy-derived
    # rules must be included here too, otherwise policies land
    # in the DB but never propagate to nftables until a UI-side
    # action triggers `set_rules/0`, and even that only stays
    # applied until the next `nexguard` container restart.
    effective_rules = MapSet.union(Rules.as_settings(), Policies.as_effective_rules())

    reply =
      {:ok,
       %{
         users: Users.as_settings(),
         devices: Devices.as_settings(),
         rules: effective_rules
       }}

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_call({:update_device_stats, stats}, _from, state) do
    {:reply, StatsUpdater.update(stats), state}
  end
end
