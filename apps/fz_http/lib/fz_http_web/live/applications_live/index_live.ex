defmodule FzHttpWeb.ApplicationsLive.Index do
  @moduledoc """
  Admin-facing list of L7-managed applications (ADR-007, ADR-014).
  Lists declared apps with a stats strip, search/status filter bar,
  and per-row delete. New + Edit ship as modal overlays from this
  page; the L7 rules editor lives on the per-app show page.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Applications

  @page_title "Applications"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    with {:ok, apps} <- Applications.list_applications(socket.assigns.subject) do
      filters = default_filters()

      {:ok,
       socket
       |> assign(:all_applications, apps)
       |> assign(:applications, apply_filters(apps, filters))
       |> assign(:filters, filters)
       |> assign(:status_options, status_options())
       |> assign(:delete_confirm, nil)
       |> assign(:page_title, @page_title)}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  # ── Filters ─────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = Map.merge(socket.assigns.filters, params)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:applications, apply_filters(socket.assigns.all_applications, filters))}
  end

  def handle_event("reset_filters", _params, socket) do
    filters = default_filters()

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:applications, apply_filters(socket.assigns.all_applications, filters))}
  end

  # ── Delete with styled confirm modal ────────────────────────────

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
         |> assign(:all_applications, apps)
         |> assign(:applications, apply_filters(apps, socket.assigns.filters))
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

  def filters_active?(%{"search" => s, "status" => st}) do
    s != "" or st != "all"
  end

  defp default_filters do
    %{"search" => "", "status" => "all"}
  end

  defp status_options do
    [
      {"Status: All", "all"},
      {"Enabled",     "enabled"},
      {"Draft",       "draft"}
    ]
  end

  defp apply_filters(apps, %{"search" => search, "status" => status}) do
    apps
    |> Enum.filter(&match_search?(&1, search))
    |> Enum.filter(&match_status?(&1, status))
  end

  defp match_search?(_app, ""), do: true

  defp match_search?(app, query) do
    q = String.downcase(query)
    name = String.downcase(app.name || "")
    hostname = String.downcase(app.hostname || "")

    String.contains?(name, q) or String.contains?(hostname, q)
  end

  defp match_status?(_app, "all"),       do: true
  defp match_status?(%{enabled: true}, "enabled"),  do: true
  defp match_status?(%{enabled: false}, "draft"),    do: true
  defp match_status?(_app, _),           do: false
end
