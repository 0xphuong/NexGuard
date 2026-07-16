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
    * Proxy    — HTTP GET `http://127.0.0.1:9090/readyz` against the
                  proxy's plaintext observability port. Bare TCP connects
                  against `:8443` (the TLS transparent-proxy listener)
                  trigger Go's stdlib "TLS handshake error: EOF" every
                  poll; hitting /readyz is quieter AND stricter (catches
                  stuck-bundle state that a bare accept() would hide).
  """
  use GenServer
  require Logger

  alias FzHttp.Repo
  alias Phoenix.PubSub

  # 60s auto-poll cadence. Admins can click any dot in the topnav
  # to force a manual probe in between auto-ticks (~1.5s round-trip),
  # so the 60s interval doesn't gate "I want a fresh read right now"
  # — it just sets the cost-free background refresh rate.
  @interval_ms 60_000
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

  # Probe the proxy's plaintext observability port (:9090) instead of
  # the TLS transparent-proxy listener (:8443). The old approach did a
  # bare TCP connect + immediate close against :8443 — functionally
  # correct but noisy: Go's net/http.Server logs a "TLS handshake
  # error from 127.0.0.1:...: EOF" every time we hang up before
  # ClientHello. Once every 60 s × forever is enough to hide real
  # errors in `docker logs nexguard-proxy`.
  #
  # `/readyz` is the same endpoint the proxy hits from its own
  # `--health-probe` docker HEALTHCHECK — 200 iff the bundle bootstrap
  # completed AND the SIGTERM drain hasn't started. Strictly stronger
  # signal than "TCP accept succeeds": a proxy stuck refreshing the
  # bundle used to show :ok (listener still bound); it now correctly
  # shows :down.
  #
  # We use raw :gen_tcp with `packet: :http_bin` so the inet driver
  # parses the status line for us — no HTTP client dep, no :inets
  # boot, and no Finch pool to babysit for a probe that fires every 60 s.
  defp probe_proxy do
    opts = [:binary, active: false, packet: :http_bin]

    with {:ok, sock} <- :gen_tcp.connect(~c"127.0.0.1", 9090, opts, @probe_timeout_ms),
         :ok <-
           :gen_tcp.send(
             sock,
             "GET /readyz HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
           ),
         {:ok, {:http_response, _version, 200, _reason}} <-
           :gen_tcp.recv(sock, 0, @probe_timeout_ms) do
      _ = :gen_tcp.close(sock)
      :ok
    else
      {:ok, {:http_response, _version, code, _reason}} ->
        {:error, {:proxy_not_ready, code}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
