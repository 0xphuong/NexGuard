defmodule FzHttp.Application do
  use Application

  def start(_type, _args) do
    supervision_tree_mode = FzHttp.Config.fetch_env!(:fz_http, :supervision_tree_mode)

    result =
      supervision_tree_mode
      |> children()
      |> Supervisor.start_link(strategy: :one_for_one, name: __MODULE__.Supervisor)

    :ok = after_start()

    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    FzHttpWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # XXX: get rid off this
  defp children(:full) do
    [
      # Infrastructure services
      FzHttp.Repo,
      FzHttp.Vault,
      {Phoenix.PubSub, name: FzHttp.PubSub},
      {FzHttp.Notifications, name: FzHttp.Notifications},
      FzHttpWeb.Presence,

      # Application
      {Postgrex.Notifications, [name: FzHttp.Repo.Notifications] ++ FzHttp.Repo.config()},
      FzHttp.Repo.Notifier,
      FzHttp.Server,
      FzHttp.VpnSessionScheduler,
      FzHttp.AuditLog.RetentionScheduler,
      FzHttp.Auth,
      # L7: signs the X-NexGuard-Identity-Jwt header (ADR-010).
      # Depends on Repo + Vault (Cloak-encrypted private_pem).
      {FzHttp.L7.JwtSigner, name: FzHttp.L7.JwtSigner},
      # L7: compiles + signs the policy bundle. Subscribes to
      # nexguard:l7:{apps,settings,groups}; calls JwtSigner on every
      # compile so must start AFTER JwtSigner.
      {FzHttp.L7.BundleBuilder, name: FzHttp.L7.BundleBuilder},
      # L7: writes /etc/nexguard/internal-hosts for CoreDNS hosts plugin.
      # Subscribes to nexguard:l7:apps; rewrites the file on every
      # Applications mutation. Independent of BundleBuilder.
      {FzHttp.L7.CoreDnsHosts, name: FzHttp.L7.CoreDnsHosts},
      # L7: writes /etc/nexguard/Corefile.generated from DB-backed
      # org settings. Subscribes to nexguard:l7:settings; rewrites
      # on every `set_dns_forward/4`. CoreDNS' `reload 1s` plugin
      # picks up the changed file without container restart.
      {FzHttp.L7.CoreDnsCorefile, name: FzHttp.L7.CoreDnsCorefile},
      # L7: daily scan of the cert library for upcoming expiries
      # (ADR-015). Logs + audit-logs at 30d / 7d / expired thresholds.
      # Independent of the other L7 services.
      FzHttp.L7.TlsCertExpiryScanner,
      # Ops health monitor — polls DB / CoreDNS / proxy every 10s and
      # caches the snapshot for the admin topnav. Layout view reads
      # via `HealthMonitor.snapshot/0` on each page render.
      FzHttp.HealthMonitor,
      FzHttpWeb.Endpoint,

      # Observability
      FzHttp.ConnectivityChecks,
      FzHttp.Telemetry
    ]
  end

  defp children(:test) do
    [
      # Infrastructure services
      FzHttp.Repo,
      FzHttp.Vault,
      {Phoenix.PubSub, name: FzHttp.PubSub},
      {FzHttp.Notifications, name: FzHttp.Notifications},
      FzHttpWeb.Presence,

      # Application
      FzHttp.Server,
      FzHttp.Auth,
      FzHttpWeb.Endpoint,

      # Observability
      FzHttp.ConnectivityChecks,
      FzHttp.Telemetry
    ]
  end

  defp children(:database) do
    [
      FzHttp.Repo,
      FzHttp.Vault
    ]
  end

  if Mix.env() == :prod do
    defp after_start do
      FzHttp.Config.validate_runtime_config!()
      bootstrap_dns()
    end
  else
    defp after_start do
      bootstrap_dns()
    end
  end

  # Seed DNS forward upstreams from the legacy `.env` vars on first
  # boot. Once an admin saves via /settings/l7, the DB value takes
  # over and these env vars are ignored (kept as the bootstrap
  # contract — see .env.example).
  defp bootstrap_dns do
    primary  = split_csv(System.get_env("COREDNS_FORWARD_TO", ""))
    fallback = split_csv(System.get_env("COREDNS_FORWARD_TO_FALLBACK", ""))

    if primary != [] do
      _ = FzHttp.OrgSettings.seed_dns_from_env(primary, fallback)
    end

    :ok
  rescue
    # OrgSettings.get/0 raises if the row doesn't exist yet (fresh
    # DB, migration pending). Don't crash boot — the supervisor will
    # restart after Repo + migrations finish, at which point this
    # runs again and seeds successfully.
    _ -> :ok
  end

  defp split_csv(""), do: []
  defp split_csv(str) when is_binary(str) do
    str
    |> String.split([",", " ", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
