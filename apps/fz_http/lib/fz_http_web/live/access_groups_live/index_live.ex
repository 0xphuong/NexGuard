defmodule FzHttpWeb.AccessGroupsLive.Index do
  @moduledoc """
  Admin-facing list of L7 access groups (ADR-014).
  Lists every group with its current member count + age, plus a
  modal-launching "New Group" button.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.AccessGroups

  @page_title "Access Groups"
  @page_subtitle "Groups gate which users can reach each L7-managed application."

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    with {:ok, groups} <- AccessGroups.list_groups(socket.assigns.subject) do
      {:ok,
       socket
       |> assign(:groups, groups)
       |> assign(:page_title, @page_title)
       |> assign(:page_subtitle, @page_subtitle)}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("delete", %{"id" => id}, socket) do
    with {:ok, group} <- AccessGroups.fetch_group_by_id(id, socket.assigns.subject),
         {:ok, _} <- AccessGroups.delete_group(group, socket.assigns.subject,
                       socket.assigns[:remote_ip]),
         {:ok, groups} <- AccessGroups.list_groups(socket.assigns.subject) do
      {:noreply,
       socket
       |> assign(:groups, groups)
       |> put_flash(:info, "Group \"#{group.name}\" deleted.")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Group not found.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete group.")}
    end
  end
end
