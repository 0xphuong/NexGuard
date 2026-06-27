defmodule FzHttpWeb.SettingLive.Security do
  @moduledoc """
  Security settings: VPN session TTL, Force MFA, Local Auth,
  Unprivileged device toggles, plus OIDC + SAML provider lists.

  Confirm-before-action gates the three security-critical toggles
  (`require_mfa`, `local_auth_enabled`, `disable_vpn_on_oidc_error`)
  via `:pending_toggle`. Each flip routes through a modal that
  spells out the user impact (lock-out risk, MFA-enrolment churn,
  revocation lag) so admins don't silently weaken the posture.

  Provider delete also gates through `:pending_delete`; the modal
  surfaces a lock-out warning when removing the provider would
  leave zero sign-in methods.
  """
  use FzHttpWeb, :live_view
  import FzHttp.Crypto, only: [rand_string: 1]
  alias FzHttp.Config

  @page_title "Security Settings"
  @page_subtitle "Configure security-related settings."

  @hour 3_600
  @day 24 * @hour

  @configs ~w[
    local_auth_enabled
    disable_vpn_on_oidc_error
    require_mfa
    allow_unprivileged_device_management
    allow_unprivileged_device_configuration
    vpn_session_duration
    openid_connect_providers
    saml_identity_providers
  ]a

  @sensitive_toggle_keys ~w[require_mfa local_auth_enabled disable_vpn_on_oidc_error]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, @page_title)
      |> assign(:page_subtitle, @page_subtitle)
      |> assign(:form_changed, false)
      |> assign(:configuration_changeset, configuration_changeset())
      |> assign(:configs, FzHttp.Config.fetch_source_and_configs!(@configs))
      |> assign(:pending_delete, nil)
      |> assign(:pending_toggle, nil)

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :id, params["id"])}
  end

  @impl Phoenix.LiveView
  def handle_event("change", %{"configuration" => attrs}, socket) do
    changeset = configuration_changeset(attrs)
    {:noreply, assign(socket, :form_changed, changeset.changes != %{})}
  end

  @impl Phoenix.LiveView
  def handle_event("save_configuration", %{"configuration" => attrs}, socket) do
    configuration = Config.fetch_db_config!()

    socket =
      case Config.update_config(configuration, attrs, socket.assigns.subject, socket.assigns.remote_ip) do
        {:ok, configuration} ->
          socket
          |> assign(:form_changed, false)
          |> assign(:configuration_changeset, Config.change_config(configuration))
          |> assign(:configs, FzHttp.Config.fetch_source_and_configs!(@configs))

        {:error, configuration_changeset} ->
          socket
          |> assign(:configuration_changeset, configuration_changeset)
      end

    {:noreply, socket}
  end

  # ── Toggle: sensitive keys go through a confirm modal first ───
  #
  # require_mfa / local_auth_enabled / disable_vpn_on_oidc_error
  # all change the org's security posture and are easy to misclick.
  # Stash the requested state in `:pending_toggle` and let the
  # template surface the impact before committing.
  @impl Phoenix.LiveView
  def handle_event("toggle", %{"config" => key} = params, socket)
      when key in @sensitive_toggle_keys do
    new_value = !!params["value"]

    {:noreply,
     assign(socket, :pending_toggle, %{
       key: key,
       new_value: new_value
     })}
  end

  def handle_event("toggle", %{"config" => key} = params, socket) do
    apply_toggle(socket, key, !!params["value"])
  end

  def handle_event("cancel_toggle", _, socket),
    do: {:noreply, assign(socket, :pending_toggle, nil)}

  def handle_event(
        "apply_toggle",
        _,
        %{assigns: %{pending_toggle: %{key: key, new_value: new_value}}} = socket
      ) do
    apply_toggle(socket, key, new_value)
  end

  defp apply_toggle(socket, key, new_value) do
    {:ok, _config} =
      Config.fetch_db_config!()
      |> Config.update_config(%{key => new_value}, socket.assigns.subject, socket.assigns.remote_ip)

    configs = FzHttp.Config.fetch_source_and_configs!(@configs)

    {:noreply,
     socket
     |> assign(:configs, configs)
     |> assign(:pending_toggle, nil)}
  end

  # ── Provider delete: lock-out guard ───────────────────────────

  @impl Phoenix.LiveView
  def handle_event("open_provider_delete", %{"type" => type, "key" => key, "label" => label}, socket) do
    {:noreply,
     assign(socket, :pending_delete, %{
       type: type,
       key: key,
       label: label,
       lockout?: lockout_after_delete?(socket.assigns.configs, type)
     })}
  end

  def handle_event("cancel_provider_delete", _params, socket) do
    {:noreply, assign(socket, :pending_delete, nil)}
  end

  def handle_event("delete", %{"type" => type, "key" => key}, socket) do
    field_key = String.to_existing_atom(type)

    config = Config.fetch_db_config!()

    providers =
      config
      |> Map.fetch!(field_key)
      |> Enum.reject(&(&1.id == key))
      |> Enum.map(&Map.from_struct/1)

    {:ok, _config} =
      Config.update_config(config, %{field_key => providers}, socket.assigns.subject, socket.assigns.remote_ip)

    configs = FzHttp.Config.fetch_source_and_configs!(@configs)

    {:noreply, socket |> assign(:configs, configs) |> assign(:pending_delete, nil)}
  end

  # ── Template helpers ──────────────────────────────────────────

  def config_has_override?({{source, _source_key}, _key}), do: source not in [:db]
  def config_has_override?({_source, _key}), do: false

  def config_value({_source, value}) do
    value
  end

  def get_provider(providers, id) do
    Enum.find(providers, &(&1.id == id))
  end

  def config_toggle_status({_source, value}) do
    if(!value, do: "on")
  end

  def config_override_source({{:env, source_key}, _value}) do
    "environment variable #{source_key}"
  end

  def session_duration_options(vpn_session_duration) do
    options = [
      {"Never", 0},
      {"Once", FzHttp.Config.Configuration.Changeset.max_vpn_session_duration()},
      {"Every Hour", @hour},
      {"Every Day", @day},
      {"Every Week", 7 * @day},
      {"Every 30 Days", 30 * @day},
      {"Every 90 Days", 90 * @day}
    ]

    values = Enum.map(options, fn {_, value} -> value end)

    if config_value(vpn_session_duration) in values do
      options
    else
      options ++
        [
          {"Every #{config_value(vpn_session_duration)} seconds",
           config_value(vpn_session_duration)}
        ]
    end
  end

  # ── Posture-aware helpers used by the stats strip + callout ──

  @doc "Headline label for the VPN-session duration tile."
  def session_duration_label(vpn_session_duration) do
    case config_value(vpn_session_duration) do
      0 -> "Never"
      v when is_integer(v) ->
        cond do
          v >= 30 * @day  -> "#{div(v, @day)}d"
          v >= @day       -> "#{div(v, @day)}d"
          v >= @hour      -> "#{div(v, @hour)}h"
          true            -> "#{v}s"
        end
      _ -> "—"
    end
  end

  @doc """
  Compute the most pressing security-posture warning. Returns nil
  when the org is in a healthy state; otherwise a `:critical |
  :warning | :info` severity + headline + detail tuple for the
  posture callout block.

  Severity priority (highest wins):
    * `:critical` — Force MFA OFF AND Local Auth ON (local users
      bypass MFA — single factor + replayable password)
    * `:warning`  — Force MFA OFF (any auth)
                  · Local Auth ON AND zero SSO providers
                    (single sign-in method, no IdP)
                  · VPN session duration = 0 (sessions never expire)
    * `:info`     — zero SSO providers configured (recommendation)
  """
  def posture_warning(configs) do
    mfa_on?   = config_value(Map.fetch!(configs, :require_mfa))
    local_on? = config_value(Map.fetch!(configs, :local_auth_enabled))
    oidc      = config_value(Map.fetch!(configs, :openid_connect_providers))
    saml      = config_value(Map.fetch!(configs, :saml_identity_providers))
    sso_count = length(oidc) + length(saml)
    duration  = config_value(Map.fetch!(configs, :vpn_session_duration))

    cond do
      not mfa_on? and local_on? ->
        {:critical, "Force MFA is OFF while Local Authentication is ON.",
          "Email + password users can sign in without a second factor. Enable Force MFA to require enrolment for everyone."}

      not mfa_on? ->
        {:warning, "Force MFA is OFF.",
          "Users can sign in without an MFA factor. Enable Force MFA to require enrolment."}

      duration == 0 ->
        {:warning, "VPN sessions never expire.",
          "Once authenticated, users keep VPN access indefinitely. Pick a non-zero duration above to force periodic re-auth."}

      local_on? and sso_count == 0 ->
        {:warning, "Single sign-in method.",
          "Local Authentication is the only way to reach the portal. Configure an SSO provider below to add a managed identity path."}

      sso_count == 0 ->
        {:info, "No SSO providers configured.",
          "Add an OpenID Connect or SAML provider below to let users sign in with your organisation's IdP."}

      true ->
        nil
    end
  end

  @doc "Total sign-in methods available (local + OIDC + SAML)."
  def signin_method_count(configs) do
    sso =
      length(config_value(Map.fetch!(configs, :openid_connect_providers))) +
        length(config_value(Map.fetch!(configs, :saml_identity_providers)))

    local = if config_value(Map.fetch!(configs, :local_auth_enabled)), do: 1, else: 0

    local + sso
  end

  # When deleting an SSO provider, would this leave zero sign-in
  # methods? Used by the delete-confirm modal to surface lock-out
  # risk upfront. Local Auth presence counts as one method.
  defp lockout_after_delete?(configs, type) do
    field_key = String.to_existing_atom(type)

    remaining_sso_after_delete =
      configs
      |> Map.fetch!(field_key)
      |> config_value()
      |> length()
      |> Kernel.-(1)
      |> max(0)

    other_sso_field =
      case type do
        "openid_connect_providers" -> :saml_identity_providers
        "saml_identity_providers" -> :openid_connect_providers
      end

    other_sso = length(config_value(Map.fetch!(configs, other_sso_field)))
    local = if config_value(Map.fetch!(configs, :local_auth_enabled)), do: 1, else: 0

    remaining_sso_after_delete + other_sso + local == 0
  end

  # Modal copy for sensitive toggles. Returns `%{title, intro,
  # impact_bullets, warn}` for the template to splat.
  def toggle_copy(%{key: "require_mfa", new_value: true}) do
    %{
      title: "Enable Force MFA",
      tone: :warning,
      intro: "Force MFA will be turned ON.",
      impact: [
        "Users without an MFA method will be redirected to enrolment on their next sign-in.",
        "Active sessions are unaffected until they expire.",
        "Local auth users keep password sign-in but also need an MFA factor."
      ],
      warn: "Verify your roll-out plan — users who can't enroll (e.g. lost authenticator) will be locked out until they re-enrol or you flip this off."
    }
  end

  def toggle_copy(%{key: "require_mfa", new_value: false}) do
    %{
      title: "Disable Force MFA",
      tone: :danger,
      intro: "Force MFA will be turned OFF.",
      impact: [
        "All users can sign in with username + password (or SSO) without a second factor.",
        "Existing MFA enrolments are preserved but not enforced.",
        "Security posture weakens — reserve for testing / break-glass."
      ],
      warn: "This is the highest-impact security toggle on this page. Are you certain?"
    }
  end

  def toggle_copy(%{key: "local_auth_enabled", new_value: true}) do
    %{
      title: "Enable Local Authentication",
      tone: :warning,
      intro: "Email + password sign-in will be available.",
      impact: [
        "Users without an SSO identity can sign in with email + password.",
        "Password reset emails will be sent through the configured outbound provider.",
        "If Force MFA is also OFF, password sign-in is single-factor."
      ],
      warn: "Prefer SSO whenever possible. If you enable local auth, also turn on Force MFA."
    }
  end

  def toggle_copy(%{key: "local_auth_enabled", new_value: false}) do
    %{
      title: "Disable Local Authentication",
      tone: :danger,
      intro: "Email + password sign-in will be removed.",
      impact: [
        "Users will only be able to sign in via configured SSO providers.",
        "Existing local-auth sessions stay until they expire.",
        "Anyone not in your IdP (contractors, break-glass) loses access."
      ],
      warn: "Verify at least one SSO provider works for every user before disabling local auth. Lock-out is recoverable only via container env-var override."
    }
  end

  def toggle_copy(%{key: "disable_vpn_on_oidc_error", new_value: true}) do
    %{
      title: "Enable VPN auto-disable on OIDC error",
      tone: :info,
      intro: "VPN access will be revoked when OIDC token refresh fails.",
      impact: [
        "When a user's IdP revokes them, the next failed token refresh disables their VPN access.",
        "Reduces the window where a revoked user keeps VPN connectivity.",
        "Requires the user to sign in again from the portal to restore access."
      ],
      warn: "Recommended. Match this to your IdP's revocation propagation policy."
    }
  end

  def toggle_copy(%{key: "disable_vpn_on_oidc_error", new_value: false}) do
    %{
      title: "Disable VPN auto-disable on OIDC error",
      tone: :warning,
      intro: "VPN access will no longer be revoked when OIDC token refresh fails.",
      impact: [
        "Users revoked at the IdP keep their VPN session until normal expiry.",
        "Useful if your IdP has flaky token endpoints, but lengthens the revocation window."
      ],
      warn: "Only disable if your IdP has slow or unreliable token refresh."
    }
  end

  defp configuration_changeset(attrs \\ %{}) do
    Config.fetch_db_config!()
    |> Config.change_config(attrs)
  end
end
