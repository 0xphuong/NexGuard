defmodule FzHttpWeb.TopbarHealthLive do
  @moduledoc """
  Three-dot service health indicator embedded in the admin topnav
  (see `admin.html.heex`). Subscribes to `nexguard:health` so the
  dots flip live when `FzHttp.HealthMonitor` re-polls every 10s OR
  when any admin clicks a dot to force a manual probe.

  Click semantics: clicking ANY dot runs a full sweep (DB + DNS +
  proxy) — the user wants a fresh snapshot, partial probes would be
  inconsistent. `phx-disable-with` greys out the buttons during the
  ~1.5s sweep so a frustrated double-click doesn't queue duplicate
  GenServer.calls.
  """
  use FzHttpWeb, :live_view_without_layout

  alias FzHttp.HealthMonitor

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: HealthMonitor.subscribe()

    {:ok,
     socket
     |> assign(:snapshot, HealthMonitor.snapshot())
     |> assign(:probing, false)}
  end

  @impl Phoenix.LiveView
  def handle_event("probe_now", _params, socket) do
    # The GenServer.call inside probe_now/0 is synchronous (~1-1.5s).
    # Setting :probing true here means the button stays disabled for
    # the round-trip, then the {:health_updated, _} broadcast from
    # the monitor will reset it.
    snapshot = HealthMonitor.probe_now()

    {:noreply,
     socket
     |> assign(:snapshot, snapshot)
     |> assign(:probing, false)}
  end

  @impl Phoenix.LiveView
  def handle_info({:health_updated, snapshot}, socket) do
    {:noreply,
     socket
     |> assign(:snapshot, snapshot)
     |> assign(:probing, false)}
  end

  # ── Template helpers ───────────────────────────────────────────

  def health_tooltip(service, state, snapshot) do
    name = case service do
      :db -> "Postgres"
      :proxy -> "L7 proxy"
      :coredns -> "CoreDNS"
      other -> Atom.to_string(other)
    end

    base = case state do
      :ok       -> "#{name} reachable"
      :degraded -> "#{name} slow / degraded"
      :down     -> "#{name} unreachable"
      _         -> "#{name} status unknown"
    end

    latency = Map.get(snapshot, :"#{service}_latency_ms")

    case latency do
      nil -> base <> " · click to probe"
      ms  -> base <> " · #{ms}ms · click to re-probe"
    end
  end
end
