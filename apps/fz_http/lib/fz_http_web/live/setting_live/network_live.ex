defmodule FzHttpWeb.SettingLive.Network do
  @moduledoc """
  Manages the Network settings LiveView.
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

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, @page_title)
      |> assign(:page_subtitle, @page_subtitle)
      |> assign(:configuration_changeset, configuration_changeset())
      |> assign(:configs, Config.fetch_source_and_configs!(@configs))
      |> assign(:cidrs_form_changed, false)
      |> assign(:no_masquerade_enabled, Config.fetch_config!(:gateway_no_masquerade_enabled))

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle", %{"config" => "gateway_no_masquerade_enabled"} = params, socket) do
    enabled = !!params["value"]

    {:ok, _config} =
      Config.fetch_db_config!()
      |> Config.update_config(%{"gateway_no_masquerade_enabled" => enabled}, socket.assigns.subject)

    reload_masquerade()

    socket =
      socket
      |> assign(:configs, Config.fetch_source_and_configs!(@configs))
      |> assign(:no_masquerade_enabled, enabled)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("change_cidrs", _params, socket) do
    {:noreply, assign(socket, :cidrs_form_changed, true)}
  end

  @impl Phoenix.LiveView
  def handle_event("save_cidrs", %{"configuration" => attrs}, socket) do
    configuration = Config.fetch_db_config!()

    socket =
      case Config.update_config(configuration, attrs) do
        {:ok, configuration} ->
          reload_masquerade()

          socket
          |> assign(:cidrs_form_changed, false)
          |> assign(:configuration_changeset, Config.change_config(configuration))
          |> assign(:configs, Config.fetch_source_and_configs!(@configs))

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

  def config_has_override?({{source, _source_key}, _key}), do: source not in [:db]
  def config_has_override?({_source, _key}), do: false
  def config_value({_source, value}), do: value
  def config_toggle_status({_source, value}), do: if(!value, do: "on")

  def config_override_source({{:env, source_key}, _value}),
    do: "environment variable #{source_key}"
end
