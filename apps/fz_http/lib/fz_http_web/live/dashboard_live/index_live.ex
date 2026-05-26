defmodule FzHttpWeb.DashboardLive.Index do
  use FzHttpWeb, :live_view

  alias FzHttp.{Users, Devices, Rules, Config, ConnectivityChecks}
  alias FzHttp.Auth.MFA

  @page_title "Dashboard"
  @stale_device_days 30

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    subject = socket.assigns.subject

    rule_count =
      case Rules.list_rules(subject) do
        {:ok, rules} -> length(rules)
        _ -> 0
      end

    user_count = Users.count()
    device_count = Devices.count()
    users_with_mfa = MFA.count_users_with_mfa_enabled()
    stale_device_count = device_count - Devices.count_active_within(@stale_device_days * 86_400)

    last_check =
      case ConnectivityChecks.list_connectivity_checks(subject, limit: 1) do
        [check | _] -> check
        _ -> nil
      end

    connectivity_enabled =
      Application.get_env(:fz_http, FzHttp.ConnectivityChecks, [])
      |> Keyword.get(:enabled, false)

    oidc_count = Config.fetch_config!(:openid_connect_providers) |> length()
    saml_count = Config.fetch_config!(:saml_identity_providers) |> length()

    socket =
      socket
      |> assign(:page_title, @page_title)
      |> assign(:user_count, user_count)
      |> assign(:device_count, device_count)
      |> assign(:active_device_count, Devices.count_active_within(180))
      |> assign(:rule_count, rule_count)
      |> assign(:admin_count, Users.count_by_role(:admin))
      |> assign(:users_with_mfa, users_with_mfa)
      |> assign(:require_mfa, Config.fetch_config!(:require_mfa))
      |> assign(:local_auth_enabled, Config.fetch_config!(:local_auth_enabled))
      |> assign(:vpn_session_duration, Config.fetch_config!(:vpn_session_duration))
      |> assign(:stale_device_count, stale_device_count)
      |> assign(:last_connectivity_check, last_check)
      |> assign(:connectivity_checks_enabled, connectivity_enabled)
      |> assign(:oidc_provider_count, oidc_count)
      |> assign(:saml_provider_count, saml_count)

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp mfa_pct(0, _), do: 0
  defp mfa_pct(with_mfa, total), do: round(with_mfa / total * 100)

  defp session_label(nil), do: "Not set"
  defp session_label(0), do: "Never expire"
  defp session_label(secs) do
    days = div(secs, 86_400)
    if days > 0, do: "#{days} days", else: "#{div(secs, 3600)} hours"
  end
end
