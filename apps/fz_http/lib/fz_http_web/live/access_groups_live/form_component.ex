defmodule FzHttpWeb.AccessGroupsLive.FormComponent do
  @moduledoc """
  Create a new access group via modal. Edit lives on the Show page
  (inline-edit name + description), so this component handles only
  the `:new` action.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.AccessGroups

  @impl Phoenix.LiveComponent
  def update(%{action: :new} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, AccessGroups.change_new_group(%{}))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate", %{"group" => attrs}, socket) do
    cs =
      attrs
      |> AccessGroups.change_new_group()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, cs)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"group" => attrs}, socket) do
    case AccessGroups.create_group(attrs, socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Group \"#{group.name}\" created.")
         |> push_redirect(to: ~p"/access-groups/#{group}")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :changeset, cs)}
    end
  end
end
