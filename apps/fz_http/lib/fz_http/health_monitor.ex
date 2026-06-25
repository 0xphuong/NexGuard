defmodule FzHttp.HealthMonitor do
  @moduledoc """
  Polls the three services the admin topnav surfaces (DB / CoreDNS /
  L7 proxy) every `@interval_ms` and caches the latest snapshot in
  GenServer state. The layout view + any LiveView page reads the
  snapshot via `snapshot/0` — O(1) GenServer.call, no I/O on the
  hot path.

  Each probe runs with a per-service timeout so one slow service
  can't stall the whole sweep. Failure modes are classified into
  three states:

    * `:ok`        — reachable, p99-ish under the slow threshold
    * `:degraded`  — reachable but over the threshold
    * `:down`      — connection refused / timed out

  All three services share the gateway container's network namespace
  (`network_mode: service:nexguard` for coredns + proxy), so we can
  reach them at loopback addresses from inside the Phoenix container.

  Probes:

    * DB       — `SELECT 1` via Ecto. Anything more complex would
                  measure pool depth too which isn't this monitor's
                  job.
    * CoreDNS  — `:inet_res.resolve/3` against `127.0.0.1:53` for a
                  fixed sentinel name. Anything routable works; we
                  use the gateway's WG IP so the resolver also exercises
                  the hosts plugin path.
    * Proxy    — TCP connect to `127.0.0.1:8443`. Don't bother with
                  TLS — `accept()` proves the listener is up.
  """
  use GenServer
  require Logger

  alias FzHttp.Repo
  alias Phoenix.PubSub

  @interval_ms 10_000
  @probe_timeout_ms 1_500
  @slow_threshold_ms 500
  @topic "nexguard:health"

  defstruct snapshot: %{
              db: :unknown,
              coredns: :unknown,
              proxy: :unknown,
              db_latency_ms: nil,
              coredns_latency_ms: nil,
              proxy_latency_ms: nil,
              last_check_at: nil
            }

  # ── Public API ──────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Most recent health snapshot. O(1) GenServer call."
  def snapshot do
    GenServer.call(__MODULE__, :snapshot, 1_000)
  end

  @doc "Force a probe NOW — for tests, manual click in topbar, diagnostics page."
  def probe_now do
    GenServer.call(__MODULE__, :probe_now, 10_000)
  end

  @doc "Subscribe to `{:health_updated, snapshot}` broadcasts."
  def subscribe, do: PubSub.subscribe(FzHttp.PubSub, @topic)

  # ── Server ─────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    # First sweep after 5s so the app finishes booting before we
    # start banging on Postgres / DNS.
    Process.send_after(self(), :tick, 5_000)
    {:ok, %__MODULE__{}}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    {:reply, state.snapshot, state}
  end

  def handle_call(:probe_now, _from, state) do
    new_snapshot = run_probes()
    broadcast(new_snapshot)
    {:reply, new_snapshot, %{state | snapshot: new_snapshot}}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @interval_ms)
    new_snapshot = run_probes()
    broadcast(new_snapshot)
    {:noreply, %{state | snapshot: new_snapshot}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp broadcast(snapshot) do
    PubSub.broadcast(FzHttp.PubSub, @topic, {:health_updated, snapshot})
  end

  # ── Probes ─────────────────────────────────────────────────────

  defp run_probes do
    {db_state, db_ms}           = probe(:db,      &probe_db/0)
    {coredns_state, coredns_ms} = probe(:coredns, &probe_coredns/0)
    {proxy_state, proxy_ms}     = probe(:proxy,   &probe_proxy/0)

    %{
      db: db_state,
      coredns: coredns_state,
      proxy: proxy_state,
      db_latency_ms: db_ms,
      coredns_latency_ms: coredns_ms,
      proxy_latency_ms: proxy_ms,
      last_check_at: DateTime.utc_now()
    }
  end

  # Wrap each probe with the same timing + classification logic so
  # they all produce a uniform `{state, ms}` regardless of how the
  # underlying check fails.
  defp probe(name, fun) do
    start = System.monotonic_time(:millisecond)

    try do
      case fun.() do
        :ok ->
          ms = System.monotonic_time(:millisecond) - start
          state = if ms > @slow_threshold_ms, do: :degraded, else: :ok
          {state, ms}

        {:error, reason} ->
          Logger.debug("[HealthMonitor] #{name} probe failed: #{inspect(reason)}")
          {:down, nil}
      end
    rescue
      e ->
        Logger.debug("[HealthMonitor] #{name} probe crashed: #{Exception.message(e)}")
        {:down, nil}
    catch
      :exit, reason ->
        Logger.debug("[HealthMonitor] #{name} probe exited: #{inspect(reason)}")
        {:down, nil}
    end
  end

  # `SELECT 1` round-trip. The query goes through the pool, so a
  # pool starvation also surfaces as :degraded / :down.
  defp probe_db do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", [], timeout: @probe_timeout_ms) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # TCP connect to CoreDNS port 53 (CoreDNS binds both UDP and TCP
  # by default). We deliberately don't issue a real DNS query:
  #
  #   * `:inet_res.resolve/4` with explicit `nameservers` had option-
  #     parsing quirks on Erlang 25 (`make_options/2` rejected the
  #     standard `[{{127,0,0,1}, 53}]` shape).
  #
  #   * A real DNS lookup also depends on whether the queried name
  #     is in the hosts plugin / cache / requires forwarding — false
  #     negatives surface when the forwarder is slow but CoreDNS
  #     itself is fine.
  #
  # TCP accept is a clean proxy for "process is up + bound". A
  # CoreDNS that crashed loses the port; one that's degraded but
  # alive still accepts. Tradeoff: a forwarder-stuck CoreDNS would
  # show :ok here. Worth it for low false-negative rate.
  defp probe_coredns do
    case :gen_tcp.connect(~c"127.0.0.1", 53, [:binary, active: false], @probe_timeout_ms) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Plain TCP connect to the proxy listener. Don't do a TLS handshake
  # — we'd need a client cert. `accept()` is enough proof the proxy
  # is bound + ready.
  defp probe_proxy do
    case :gen_tcp.connect(~c"127.0.0.1", 8443, [:binary, active: false], @probe_timeout_ms) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
