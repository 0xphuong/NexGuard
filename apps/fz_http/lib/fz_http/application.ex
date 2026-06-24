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
      # L7: daily scan of the cert library for upcoming expiries
      # (ADR-015). Logs + audit-logs at 30d / 7d / expired thresholds.
      # Independent of the other L7 services.
      FzHttp.L7.TlsCertExpiryScanner,
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
    end
  else
    defp after_start do
      :ok
    end
  end
end
