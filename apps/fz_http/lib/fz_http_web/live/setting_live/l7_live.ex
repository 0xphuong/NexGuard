defmodule FzHttpWeb.SettingLive.L7 do
  @moduledoc """
  Org-level L7 enforcement toggle (ADR-014).

  Surface for the single `org_settings.l7_enabled` boolean — the kill
  switch that controls whether nftables TPROXY chain is installed and
  whether CoreDNS + the L7 proxy actively route requests for declared
  applications. Per-app `enabled` is layered on top of this.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{OrgSettings, Applications}

  @page_title "L7 Enforcement"
  @page_subtitle "Org-wide kill switch for the L7 ZTNA proxy."

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, @page_title)
     |> assign(:page_subtitle, @page_subtitle)
     |> assign(:confirm, nil)
     |> reload_assigns()}
  end

  defp reload_assigns(socket) do
    settings = OrgSettings.get()

    enabled_apps_count =
      case Applications.list_applications(socket.assigns.subject) do
        {:ok, apps} -> Enum.count(apps, & &1.enabled)
        _ -> 0
      end

    socket
    |> assign(:settings, settings)
    |> assign(:enabled_apps_count, enabled_apps_count)
  end

  # ── Confirm-before-toggle ──────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("request_enable", _, socket),
    do: {:noreply, assign(socket, :confirm, :enable)}

  def handle_event("request_disable", _, socket),
    do: {:noreply, assign(socket, :confirm, :disable)}

  def handle_event("cancel", _, socket),
    do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("apply", _, %{assigns: %{confirm: :enable}} = socket) do
    case OrgSettings.set_l7_enabled(true, socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:confirm, nil)
         |> reload_assigns()
         |> put_flash(:info, "L7 enforcement enabled.")}

      _ ->
        {:noreply,
         socket
         |> assign(:confirm, nil)
         |> put_flash(:error, "Could not enable L7.")}
    end
  end

  def handle_event("apply", _, %{assigns: %{confirm: :disable}} = socket) do
    case OrgSettings.set_l7_enabled(false, socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:confirm, nil)
         |> reload_assigns()
         |> put_flash(:info, "L7 enforcement disabled — kill switch flipped.")}

      _ ->
        {:noreply,
         socket
         |> assign(:confirm, nil)
         |> put_flash(:error, "Could not disable L7.")}
    end
  end
end
