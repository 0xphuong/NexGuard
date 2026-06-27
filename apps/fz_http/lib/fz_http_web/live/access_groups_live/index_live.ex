defmodule FzHttpWeb.AccessGroupsLive.Index do
  @moduledoc """
  Admin-facing list of L7 access groups (ADR-014). Stats strip
  pulses org-wide totals; the filter bar narrows by name/description
  substring or by source (manual / IdP-synced / system). Per-row
  delete is gated by `data-confirm` for browsers without JS modal.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.AccessGroups

  @page_title "Access Groups"
  @page_subtitle "Groups gate which users can reach each L7-managed application."

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    with {:ok, groups} <- AccessGroups.list_groups(socket.assigns.subject) do
      filters = default_filters()

      {:ok,
       socket
       |> assign(:all_groups, groups)
       |> assign(:groups, apply_filters(groups, filters))
       |> assign(:filters, filters)
       |> assign(:source_options, source_options())
       |> assign(:page_title, @page_title)
       |> assign(:page_subtitle, @page_subtitle)}
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
     |> assign(:groups, apply_filters(socket.assigns.all_groups, filters))}
  end

  def handle_event("reset_filters", _params, socket) do
    filters = default_filters()

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:groups, apply_filters(socket.assigns.all_groups, filters))}
  end

  @impl Phoenix.LiveView
  def handle_event("delete", %{"id" => id}, socket) do
    with {:ok, group} <- AccessGroups.fetch_group_by_id(id, socket.assigns.subject),
         {:ok, _} <- AccessGroups.delete_group(group, socket.assigns.subject,
                       socket.assigns[:remote_ip]),
         {:ok, groups} <- AccessGroups.list_groups(socket.assigns.subject) do
      {:noreply,
       socket
       |> assign(:all_groups, groups)
       |> assign(:groups, apply_filters(groups, socket.assigns.filters))
       |> put_flash(:info, "Group \"#{group.name}\" deleted.")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Group not found.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete group.")}
    end
  end

  # ── Template helpers ───────────────────────────────────────────

  def filters_active?(%{"search" => s, "source" => src}) do
    s != "" or src != "all"
  end

  defp default_filters do
    %{"search" => "", "source" => "all"}
  end

  defp source_options do
    [
      {"Source: All", "all"},
      {"Manual",      "manual"},
      {"IdP-synced",  "idp_sync"},
      {"System",      "system"}
    ]
  end

  defp apply_filters(groups, %{"search" => search, "source" => source}) do
    groups
    |> Enum.filter(&match_search?(&1, search))
    |> Enum.filter(&match_source?(&1, source))
  end

  defp match_search?(_group, ""), do: true

  defp match_search?(group, query) do
    q = String.downcase(query)
    name = String.downcase(group.name || "")
    desc = String.downcase(group.description || "")

    String.contains?(name, q) or String.contains?(desc, q)
  end

  defp match_source?(_group, "all"), do: true
  defp match_source?(group, source), do: Atom.to_string(group.source) == source
end
