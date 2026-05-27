defmodule FzHttpWeb.UserLive.Show do
  @moduledoc """
  Handles showing users.
  XXX: Admin only
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{Devices, Auth.OIDC, Users}
  alias FzHttpWeb.ErrorHelpers

  @impl Phoenix.LiveView

  def mount(%{"id" => user_id} = _params, _session, socket) do
    {:ok, user} = Users.fetch_user_by_id(user_id, socket.assigns.subject)
    {:ok, devices} = Devices.list_devices_for_user(user, socket.assigns.subject)
    connections = OIDC.list_connections(user)

    {:ok,
     socket
     |> assign(:devices, devices)
     |> assign(:device_config, socket.assigns[:device_config])
     |> assign(:connections, connections)
     |> assign(:user, user)
     |> assign(:page_title, "Users")
     |> assign(:rules_path, ~p"/rules")
     |> assign(:show_delete_confirm, false)
     |> assign(:show_mote_confirm, false)}
  end

  @doc """
  Called when a modal is dismissed; reload devices.
  """
  @impl Phoenix.LiveView
  def handle_params(%{"id" => user_id} = _params, _url, socket) do
    {:ok, user} = Users.fetch_user_by_id(user_id, socket.assigns.subject)
    {:ok, devices} = Devices.list_devices_for_user(user, socket.assigns.subject)

    socket =
      socket
      |> assign(:devices, devices)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("confirm_delete", _params, socket) do
    {:noreply, assign(socket, :show_delete_confirm, true)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :show_delete_confirm, false)}
  end

  def handle_event("open_mote_confirm", _params, socket) do
    {:noreply, assign(socket, :show_mote_confirm, true)}
  end

  def handle_event("cancel_mote", _params, socket) do
    {:noreply, assign(socket, :show_mote_confirm, false)}
  end

  def handle_event("confirm_mote", %{"user_id" => user_id}, socket) do
    role = mote_target_role(socket.assigns.user)

    with {:ok, user} <- Users.fetch_user_by_id(user_id, socket.assigns.subject),
         {:ok, user} <- Users.update_user(user, %{role: role}, socket.assigns.subject) do
      FzHttpWeb.Endpoint.broadcast("users_socket:#{user.id}", "disconnect", %{})

      {:noreply,
       socket
       |> assign(:user, user)
       |> assign(:show_mote_confirm, false)
       |> put_flash(:info, "User updated successfully.")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:show_mote_confirm, false)
         |> put_flash(:error, "Error, #{ErrorHelpers.aggregated_errors(changeset)}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:show_mote_confirm, false)
         |> put_flash(:error, "Error updating user: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_user", %{"user_id" => user_id}, socket) do
    if user_id == "#{socket.assigns.current_user.id}" do
      {:noreply,
       socket
       |> put_flash(:error, "Use the account section to delete your account.")}
    else
      {:ok, user} = Users.fetch_user_by_id(user_id, socket.assigns.subject)

      case Users.delete_user(user, socket.assigns.subject) do
        {:ok, _} ->
          FzHttpWeb.Endpoint.broadcast("users_socket:#{user.id}", "disconnect", %{})

          {:noreply,
           socket
           |> put_flash(:info, "User deleted successfully.")
           |> push_redirect(to: ~p"/users")}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             "Error deleting user: #{ErrorHelpers.aggregated_errors(changeset)}"
           )}
      end
    end
  end

  @action_and_message %{
    admin: %{
      action: "Demote",
      message: "This will remove admin permissions from the user.",
      icon: "mdi-account-arrow-down",
      target_role: :unprivileged
    },
    unprivileged: %{
      action: "Promote",
      message: "This will give admin permissions to the user.",
      icon: "mdi-account-arrow-up",
      target_role: :admin
    }
  }

  defp mote(%{role: role}), do: @action_and_message[role].action
  defp mote_message(%{role: role}), do: @action_and_message[role].message
  defp mote_icon(%{role: role}), do: @action_and_message[role].icon
  defp mote_target_role(%{role: role}), do: @action_and_message[role].target_role
end
