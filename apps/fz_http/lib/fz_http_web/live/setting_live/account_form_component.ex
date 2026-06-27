defmodule FzHttpWeb.SettingLive.AccountFormComponent do
  @moduledoc """
  Edit-account modal for the signed-in admin. Email + new password.

  Form harmonised with the user-management edit form (commit
  `452b5d7`): live validate via `phx-change`, dedicated `.ng-field`
  family on every input (no settings-class drift), explicit email-
  change warning, and a "leave blank to keep" hint on the password
  field so the admin doesn't think they have to type one.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Users

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    changeset = Users.change_user(assigns.user)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      socket.assigns.user
      |> Users.change_user(user_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"user" => user_params}, socket) do
    user = socket.assigns.user

    case Users.update_user(user, user_params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account updated successfully.")
         |> redirect(to: socket.assigns.return_to)}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end
end
