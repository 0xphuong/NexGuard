defmodule FzHttp.L7.BundleBuilder do
  @moduledoc """
  Compiles the L7 policy bundle the proxy reads from
  `GET /internal/bundle.json` (ADR-010).

  Subscribes to three PubSub source-of-truth topics:

    * `nexguard:l7:apps`     — `FzHttp.Applications` mutations
    * `nexguard:l7:settings` — `FzHttp.OrgSettings.set_l7_enabled/3`
    * `nexguard:l7:groups`   — `FzHttp.AccessGroups` mutations (wired in Phase 5)

  Any event schedules a debounced recompile (`@debounce_ms = 300 ms`)
  so a burst of admin clicks coalesces into one compile.

  Compile output is stored in a `:named_table`, `:public` ETS table:

    * `{:current, entry}`         — latest version
    * `{{:history, version}, entry}` — last `@history_size` versions for
      last-known-good rollback by the proxy
    * `{:version_counter, n}`     — monotonic version source

  Controllers (`BundleController` in Phase 4) read the table directly
  without going through the GenServer — O(1) hot path. Reads are
  concurrent-safe (`read_concurrency: true`).

  After every successful compile we PubSub `{:bundle_updated, version}`
  on `nexguard:l7:bundle` so the proxy fetches eagerly instead of
  long-polling. Verification: the proxy reads the JWT from
  `X-NexGuard-Bundle-Signature`, extracts the `bundle_sha256` claim,
  and compares it to its own SHA-256 of the response body. This is
  the pragmatic equivalent of an RFC 7797 detached JWS using the
  existing `JwtSigner.sign/2` surface.

  Follows the singleton-with-test-override convention shared with
  `FzHttp.Notifications` and `FzHttp.L7.JwtSigner`: `start_link/1`
  honors `opts[:name]` and `opts[:table]` so tests can spawn isolated
  instances under `start_supervised!/1`.
  """

  use GenServer
  import Ecto.Query

  alias FzHttp.{Applications, OrgSettings, Repo}
  alias FzHttp.AccessGroups.Group
  alias FzHttp.L7.JwtSigner
  alias Phoenix.PubSub

  @subscribe_topics ~w(nexguard:l7:apps nexguard:l7:settings nexguard:l7:groups)
  @publish_topic "nexguard:l7:bundle"
  @default_table :l7_bundle
  @history_size 3
  @debounce_ms 300
  @schema_version 1

  # ── Client API ─────────────────────────────────────────────────

  def start_link(opts \\ []) do
    if opts[:name] do
      GenServer.start_link(__MODULE__, opts, name: opts[:name])
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "Returns the latest compiled bundle entry, or nil before the first compile."
  def current(table \\ @default_table) do
    case :ets.lookup(table, :current) do
      [{:current, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Returns a historical bundle entry by version, if still in the LKG ring."
  def history(version) when is_integer(version), do: history(@default_table, version)

  def history(table, version) do
    case :ets.lookup(table, {:history, version}) do
      [{{:history, _}, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Force a compile NOW, bypassing the debounce. Returns `{:ok, version}`."
  def compile_now, do: compile_now(__MODULE__)
  def compile_now(server), do: GenServer.call(server, :compile_now, 10_000)

  @doc "Subscribe the caller to `{:bundle_updated, version}` broadcasts."
  def subscribe_updates, do: PubSub.subscribe(FzHttp.PubSub, @publish_topic)

  # ── Server callbacks ───────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    table = Keyword.get(opts, :table, @default_table)
    subscribe? = Keyword.get(opts, :subscribe, true)
    compile_on_boot? = Keyword.get(opts, :compile_on_boot, true)

    if :ets.info(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    end

    if subscribe? do
      Enum.each(@subscribe_topics, &PubSub.subscribe(FzHttp.PubSub, &1))
    end

    # Compile once on boot so the first /internal/bundle.json request
    # never sees an empty table. Tests can disable this to control
    # version numbering deterministically.
    if compile_on_boot?, do: send(self(), :compile)

    {:ok, %{table: table, pending_timer: nil}}
  end

  @impl GenServer
  def handle_call(:compile_now, _from, state) do
    state = cancel_timer(state)
    {:reply, do_compile(state.table), state}
  end

  # Source-of-truth events → schedule debounced compile.
  @impl GenServer
  def handle_info(:apps_changed, state), do: {:noreply, schedule(state)}
  def handle_info({:l7_enabled_changed, _}, state), do: {:noreply, schedule(state)}
  def handle_info({:groups_changed, _}, state), do: {:noreply, schedule(state)}
  def handle_info(:groups_changed, state), do: {:noreply, schedule(state)}

  # Debounce timer fired — drop the ref, then compile.
  def handle_info(:compile, state) do
    state = %{state | pending_timer: nil}
    _ = do_compile(state.table)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── Scheduling ─────────────────────────────────────────────────

  defp schedule(state) do
    state = cancel_timer(state)
    ref = Process.send_after(self(), :compile, @debounce_ms)
    %{state | pending_timer: ref}
  end

  defp cancel_timer(%{pending_timer: nil} = state), do: state

  defp cancel_timer(%{pending_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | pending_timer: nil}
  end

  # ── Compile ────────────────────────────────────────────────────

  defp do_compile(table) do
    version = next_version(table)
    compiled_at = DateTime.utc_now() |> DateTime.to_iso8601()

    bundle = %{
      "schema_version" => @schema_version,
      "bundle_version" => version,
      "compiled_at" => compiled_at,
      "org_settings" => %{"l7_enabled" => OrgSettings.l7_enabled?()},
      "jwks" => JwtSigner.jwks(),
      "apps" => list_apps(),
      "groups" => list_groups()
    }

    bundle_json = Jason.encode!(bundle)

    case sign_bundle(bundle_json) do
      {:ok, signature} ->
        entry = %{
          version: version,
          bundle_json: bundle_json,
          signature: signature,
          compiled_at: compiled_at
        }

        write_entry(table, version, entry)
        broadcast_updated(version)
        {:ok, version}

      {:error, _} = err ->
        err
    end
  end

  defp list_apps do
    Applications.list_enabled_for_bundle()
    |> Enum.map(fn app ->
      %{
        "id" => app.id,
        "hostname" => app.hostname,
        "virtual_ip" => FzHttp.Types.INET.to_string(app.virtual_ip),
        "backend" => app.backend,
        "tls_mode" => app.tls_mode,
        "cert_source" => app.cert_source,
        "cert_pem" => app.cert_pem,
        "l7_rules" => app.l7_rules,
        "allowed_group_ids" => Enum.map(app.allowed_groups, & &1.id),
        # Schema doesn't carry these fields yet — emit empty so the
        # bundle shape is stable for the proxy contract. When the
        # schema adds them, this projection picks them up automatically.
        "inject_headers" => [],
        "strip_headers" => []
      }
    end)
  end

  defp list_groups do
    from(g in Group, preload: :users)
    |> Repo.all()
    |> Enum.map(fn g ->
      %{
        "id" => g.id,
        "name" => g.name,
        "user_ids" => Enum.map(g.users, & &1.id)
      }
    end)
  end

  # SHA-256 claim instead of strict RFC 7797 detached JWS: the proxy
  # computes SHA-256 of the body, verifies the JWT, then compares the
  # `bundle_sha256` claim to its hash. Functionally equivalent and
  # reuses the existing JwtSigner.sign/2 surface — no new key API.
  defp sign_bundle(bundle_json) do
    sha = :crypto.hash(:sha256, bundle_json) |> Base.encode16(case: :lower)
    JwtSigner.sign(%{"bundle_sha256" => sha}, expires_in: 3600)
  end

  # ── ETS helpers ────────────────────────────────────────────────

  # Atomic monotonic counter. Initial value 0 → first compile returns 1.
  defp next_version(table) do
    :ets.update_counter(table, :version_counter, 1, {:version_counter, 0})
  end

  defp write_entry(table, version, entry) do
    :ets.insert(table, {:current, entry})
    :ets.insert(table, {{:history, version}, entry})

    # LKG ring: drop oldest beyond the window.
    pruneable = version - @history_size

    if pruneable > 0 do
      :ets.delete(table, {:history, pruneable})
    end

    :ok
  end

  defp broadcast_updated(version) do
    PubSub.broadcast(FzHttp.PubSub, @publish_topic, {:bundle_updated, version})
  end
end
