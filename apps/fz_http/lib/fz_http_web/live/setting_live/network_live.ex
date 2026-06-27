defmodule FzHttpWeb.SettingLive.Network do
  @moduledoc """
  Gateway routing + NAT settings.

  Two controls drive nftables rule reload:
    * `gateway_no_masquerade_enabled` — toggle: when ON, packets to
      `gateway_no_masquerade_cidrs` are routed without MASQUERADE so
      destination servers see the real VPN client IP. Requires those
      servers to carry a return route to the WireGuard subnet
      (default `100.64.0.0/10`). Mis-configured, traffic to those
      subnets silently breaks — so enabling goes through a confirm
      modal that disclosures the requirement.
    * `gateway_no_masquerade_cidrs` — comma CIDR list. Live-validated
      against the Config changeset; save button stays disabled until
      a valid change exists.
  """
  use FzHttpWeb, :live_view
  require Logger
  alias FzHttp.Config

  @page_title "Network"
  @page_subtitle "Gateway routing and NAT settings."

  @configs ~w[
    gateway_no_masquerade_enabled
    gateway_no_masquerade_cidrs
  ]a

  # RFC 1918 fallback shown in the confirm modal when the admin
  # hasn't configured an explicit CIDR list yet.
  @default_cidrs ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, @page_title)
      |> assign(:page_subtitle, @page_subtitle)
      |> assign(:configuration_changeset, configuration_changeset())
      |> assign(:configs, Config.fetch_source_and_configs!(@configs))
      |> assign(:cidrs_form_changed, false)
      |> assign(:pending_toggle, nil)
      |> assign(:no_masquerade_enabled, Config.fetch_config!(:gateway_no_masquerade_enabled))

    {:ok, socket}
  end

  # ── Toggle: confirm-before-enable, instant-disable ─────────────
  #
  # Disabling returns the gateway to the safe MASQUERADE default —
  # no confirm needed. Enabling routes traffic away from MASQUERADE,
  # which silently breaks subnets without a return route — so the
  # admin sees an upfront modal listing the affected CIDRs before
  # the nftables ruleset flips.
  @impl Phoenix.LiveView
  def handle_event("toggle", %{"config" => "gateway_no_masquerade_enabled", "value" => "on"}, socket) do
    {:noreply, assign(socket, :pending_toggle, :enable)}
  end

  def handle_event("toggle", %{"config" => "gateway_no_masquerade_enabled"}, socket) do
    apply_toggle(socket, false)
  end

  def handle_event("cancel_toggle", _, socket),
    do: {:noreply, assign(socket, :pending_toggle, nil)}

  def handle_event("apply_toggle", _, %{assigns: %{pending_toggle: :enable}} = socket) do
    apply_toggle(socket, true)
  end

  defp apply_toggle(socket, enabled) do
    case Config.fetch_db_config!()
         |> Config.update_config(%{"gateway_no_masquerade_enabled" => enabled},
                                  socket.assigns.subject, socket.assigns.remote_ip) do
      {:ok, _} ->
        Logger.info(
          "[network] Preserve Client IP toggled #{if enabled, do: "ON", else: "OFF"} " <>
            "by subject=#{inspect(socket.assigns.subject.actor)}"
        )

        reload_masquerade()

        msg =
          if enabled,
            do: "Preserve Client IP enabled — no-MASQUERADE for selected subnets.",
            else: "Preserve Client IP disabled — MASQUERADE restored."

        socket =
          socket
          |> assign(:configs, Config.fetch_source_and_configs!(@configs))
          |> assign(:no_masquerade_enabled, enabled)
          |> assign(:pending_toggle, nil)
          |> put_flash(:info, msg)

        {:noreply, socket}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:pending_toggle, nil)
         |> put_flash(:error, "Could not update masquerade toggle.")}
    end
  end

  # ── CIDR form ──────────────────────────────────────────────────

  # Live validate on every change so bad CIDRs surface as you type
  # instead of waiting for submit. Save button toggles off when the
  # changeset has no changes (or has errors).
  @impl Phoenix.LiveView
  def handle_event("change_cidrs", %{"configuration" => attrs}, socket) do
    changeset =
      Config.fetch_db_config!()
      |> Config.change_config(attrs)
      |> Map.put(:action, :validate)

    # Save button stays disabled until there's a change AND it's
    # valid — without the `valid?` guard, an invalid CIDR like
    # "10.0.0.0" still set `:cidrs_form_changed = true` because the
    # changes map was non-empty.
    {:noreply,
     socket
     |> assign(:configuration_changeset, changeset)
     |> assign(:cidrs_form_changed, map_size(changeset.changes) > 0 and changeset.valid?)}
  end

  @impl Phoenix.LiveView
  def handle_event("save_cidrs", %{"configuration" => attrs}, socket) do
    configuration = Config.fetch_db_config!()

    socket =
      case Config.update_config(configuration, attrs, socket.assigns.subject, socket.assigns.remote_ip) do
        {:ok, configuration} ->
          Logger.info(
            "[network] no-MASQUERADE CIDR list updated by " <>
              "subject=#{inspect(socket.assigns.subject.actor)}"
          )

          reload_masquerade()

          socket
          |> assign(:cidrs_form_changed, false)
          |> assign(:configuration_changeset, Config.change_config(configuration))
          |> assign(:configs, Config.fetch_source_and_configs!(@configs))
          |> put_flash(:info, "Internal subnets saved — nftables reloaded.")

        {:error, changeset} ->
          assign(socket, :configuration_changeset, changeset)
      end

    {:noreply, socket}
  end

  defp reload_masquerade do
    FzWall.Server.reload_masquerade()
  rescue
    e -> Logger.warning("Failed to reload masquerade rules: #{inspect(e)}")
  end

  defp configuration_changeset(attrs \\ %{}) do
    Config.fetch_db_config!()
    |> Config.change_config(attrs)
  end

  # ── Template helpers ───────────────────────────────────────────

  def config_has_override?({{source, _source_key}, _key}), do: source not in [:db]
  def config_has_override?({_source, _key}), do: false
  def config_value({_source, value}), do: value
  def config_toggle_status({_source, value}), do: if(!value, do: "on")

  def config_override_source({{:env, source_key}, _value}),
    do: "environment variable #{source_key}"

  @doc """
  Subnet list shown in the enable-confirm modal. Falls back to the
  RFC 1918 default that nftables uses when the admin hasn't entered
  a custom list yet — so the modal always names *something* concrete
  rather than saying "your configured subnets" abstractly.
  """
  def pending_cidrs(configs) do
    case Map.get(configs, :gateway_no_masquerade_cidrs) do
      {_source, value} when is_list(value) and value != [] -> value
      _ -> @default_cidrs
    end
  end
end
