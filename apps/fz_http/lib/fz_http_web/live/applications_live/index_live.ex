defmodule FzHttpWeb.ApplicationsLive.Index do
  @moduledoc """
  Admin-facing list of L7-managed applications (ADR-007, ADR-014).
  Wave 3a — Index page only. New/Edit form ships in Wave 3b; L7
  rules editor ships in Wave 3c.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Applications

  @page_title "Applications"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    with {:ok, apps} <- Applications.list_applications(socket.assigns.subject) do
      {:ok,
       socket
       |> assign(:applications, apps)
       |> assign(:delete_confirm, nil)
       |> assign(:page_title, @page_title)}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  # ── Delete with styled confirm modal ────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    case Applications.fetch_application_by_id(id, socket.assigns.subject) do
      {:ok, app} ->
        {:noreply, assign(socket, :delete_confirm, app)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Application not found.")}
    end
  end

  def handle_event("cancel_delete", _, socket),
    do: {:noreply, assign(socket, :delete_confirm, nil)}

  def handle_event("delete", _params, %{assigns: %{delete_confirm: app}} = socket)
      when not is_nil(app) do
    case Applications.delete_application(app, socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, _} ->
        {:ok, apps} = Applications.list_applications(socket.assigns.subject)

        {:noreply,
         socket
         |> assign(:applications, apps)
         |> assign(:delete_confirm, nil)
         |> put_flash(:info, "Application \"#{app.name}\" deleted.")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:delete_confirm, nil)
         |> put_flash(:error, "Could not delete application.")}
    end
  end

  # ── Helpers for template ───────────────────────────────────────

  @doc false
  def vip_to_string(%Postgrex.INET{address: addr}),
    do: addr |> :inet.ntoa() |> List.to_string()

  def vip_to_string(_), do: "—"
end
