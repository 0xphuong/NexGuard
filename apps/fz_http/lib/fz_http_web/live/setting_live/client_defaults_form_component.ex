defmodule FzHttpWeb.SettingLive.ClientDefaultsFormComponent do
  @moduledoc """
  Handles updating client defaults form.
  """
  use FzHttpWeb, :live_component
  alias FzHttp.Config

  @configs ~w[
    default_client_allowed_ips
    default_client_dns
    default_client_endpoint
    default_client_persistent_keepalive
    default_client_mtu
  ]a

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign(:configs, FzHttp.Config.fetch_source_and_configs!(@configs))

    {:ok, socket}
  end

  # Live validation — fires on every form change so the admin sees
  # bad CIDRs / IPs / MTU errors as they type instead of finding out
  # on submit. Mirrors the apps/cert form patterns.
  @impl Phoenix.LiveComponent
  def handle_event("validate", %{"configuration" => params}, socket) do
    params =
      params
      |> Map.update("default_client_dns", nil, &binary_to_list/1)
      |> Map.update("default_client_allowed_ips", nil, &binary_to_list/1)

    changeset =
      socket.assigns.changeset.data
      |> Config.change_config(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"configuration" => configuration_params}, socket) do
    configuration_params =
      configuration_params
      |> Map.update("default_client_dns", nil, &binary_to_list/1)
      |> Map.update("default_client_allowed_ips", nil, &binary_to_list/1)

    configuration = Config.fetch_db_config!()

    socket =
      case Config.update_config(configuration, configuration_params, socket.assigns.subject, socket.assigns[:remote_ip]) do
        {:ok, configuration} ->
          socket
          |> assign(:changeset, Config.change_config(configuration))

        {:error, changeset} ->
          socket
          |> assign(:changeset, changeset)
      end

    {:noreply, socket}
  end

  # Parse a comma-separated string into a clean list. Each item is
  # trimmed individually — without this, `String.split("a, b", ",")`
  # leaves `[" b"]` with a leading space, and the
  # binary_to_list ↔ list_value round-trip (triggered by every
  # phx-change validate) widened the value by one extra space per
  # keystroke. Pretty visible on the multi-line Allowed IPs textarea.
  defp binary_to_list(binary) when is_binary(binary) do
    binary
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp binary_to_list(list) when is_list(list),
    do: list

  def config_has_override?({{source, _source_key}, _key}) do
    source not in [:db]
  end

  def config_has_override?({_source, _key}) do
    false
  end

  def config_value({_source, value}) do
    value
  end

  def config_override_source({{:env, source_key}, _value}) do
    "environment variable #{source_key}"
  end
end
