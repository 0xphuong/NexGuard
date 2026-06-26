defmodule FzHttpWeb.UserLive.Show do
  @moduledoc """
  Handles showing users.
  XXX: Admin only
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{Devices, Auth.OIDC, Users, AccessGroups, Repo}
  alias FzHttp.Users.User.Query, as: UserQuery
  alias FzHttpWeb.ErrorHelpers

  @mfa_stale_days 30

  @impl Phoenix.LiveView

  def mount(%{"id" => user_id} = _params, _session, socket) do
    {:ok, user} = Users.fetch_user_by_id(user_id, socket.assigns.subject)
    user = hydrate_user(user)
    {:ok, devices} = Devices.list_devices_for_user(user, socket.assigns.subject)
    connections = OIDC.list_connections(user)

    {:ok,
     socket
     |> assign(:devices, devices)
     |> assign(:device_config, socket.assigns[:device_config])
     |> assign(:connections, connections)
     |> assign(:user, user)
     |> assign(:tab, tab_for_action(socket.assigns[:live_action]))
     |> assign(:page_title, "Users")
     |> assign(:rules_path, ~p"/rules")
     |> assign(:show_delete_confirm, false)
     |> assign(:show_mote_confirm, false)
     |> assign(:remove_group_confirm, nil)
     |> assign(:scope_change_confirm, nil)
     |> load_l7_assigns(user)}
  end

  # Re-fetch with index aggregates (device_count + last_handshake +
  # mfa_count + mfa_last_used) so the hero + Overview card can display
  # security freshness without an N+1.
  defp hydrate_user(user) do
    UserQuery.by_id(user.id)
    |> UserQuery.hydrate_index()
    |> Repo.one()
    |> case do
      nil -> user
      hydrated -> hydrated
    end
  end

  # ── L7 group memberships + access_scope ──────────────────────────

  defp load_l7_assigns(socket, user) do
    user_groups =
      case AccessGroups.list_groups(socket.assigns.subject) do
        {:ok, all} ->
          {user_groups, available} =
            Enum.split_with(all, fn g ->
              g.id in Enum.map(AccessGroups.list_groups_for_user(user), & &1.id)
            end)

          socket
          |> assign(:user_groups, user_groups)
          |> assign(:available_groups, available)

        _ ->
          socket
          |> assign(:user_groups, [])
          |> assign(:available_groups, [])
      end

    user_groups
  end

  @doc """
  Called on every URL change. Re-reads devices (in case a device
  modal was just dismissed) and assigns `:tab` derived from the
  live_action so the template can pick the active panel.
  """
  @impl Phoenix.LiveView
  def handle_params(%{"id" => user_id} = _params, _url, socket) do
    {:ok, user} = Users.fetch_user_by_id(user_id, socket.assigns.subject)
    {:ok, devices} = Devices.list_devices_for_user(user, socket.assigns.subject)

    {:noreply,
     socket
     |> assign(:devices, devices)
     |> assign(:tab, tab_for_action(socket.assigns.live_action))}
  end

  # `:edit` opens the edit modal — tab underneath stays on Overview.
  # `:new_device` opens the add-device modal — surface the Devices
  # tab underneath so closing the modal lands in the right place.
  defp tab_for_action(:devices),    do: :devices
  defp tab_for_action(:new_device), do: :devices
  defp tab_for_action(:groups),     do: :groups
  defp tab_for_action(:access),     do: :access
  defp tab_for_action(:connections),do: :connections
  defp tab_for_action(:danger),     do: :danger
  defp tab_for_action(_),           do: :overview

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
         {:ok, user} <- Users.update_user(user, %{role: role}, socket.assigns.subject, socket.assigns.remote_ip) do
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

  # ── Group membership handlers ────────────────────────────────────

  def handle_event("add_to_group", %{"group_id" => group_id}, socket) do
    user = socket.assigns.user

    with {:ok, group} <- AccessGroups.fetch_group_by_id(group_id, socket.assigns.subject),
         {:ok, _} <- AccessGroups.add_member(group, user, socket.assigns.subject,
                       socket.assigns.remote_ip) do
      {:noreply,
       socket
       |> load_l7_assigns(user)
       |> put_flash(:info, "Added to #{group.name}.")}
    else
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not add to group.")}
    end
  end

  def handle_event("confirm_remove_from_group", %{"group_id" => group_id}, socket) do
    case AccessGroups.fetch_group_by_id(group_id, socket.assigns.subject) do
      {:ok, group} ->
        {:noreply, assign(socket, :remove_group_confirm, group)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Group not found.")}
    end
  end

  def handle_event("cancel_remove_from_group", _, socket),
    do: {:noreply, assign(socket, :remove_group_confirm, nil)}

  def handle_event("remove_from_group", _params, %{assigns: %{remove_group_confirm: group}} = socket)
      when not is_nil(group) do
    user = socket.assigns.user

    case AccessGroups.remove_member(group, user, socket.assigns.subject, socket.assigns.remote_ip) do
      {:ok, :removed} ->
        {:noreply,
         socket
         |> assign(:remove_group_confirm, nil)
         |> load_l7_assigns(user)
         |> put_flash(:info, "Removed from #{group.name}.")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:remove_group_confirm, nil)
         |> put_flash(:error, "Could not remove from group.")}
    end
  end

  # ── Access scope toggle ──────────────────────────────────────────

  def handle_event("confirm_set_access_scope", %{"scope" => scope}, socket)
      when scope in ["limited", "all"] do
    {:noreply, assign(socket, :scope_change_confirm, String.to_existing_atom(scope))}
  end

  def handle_event("cancel_set_access_scope", _, socket),
    do: {:noreply, assign(socket, :scope_change_confirm, nil)}

  def handle_event("set_access_scope", _params,
                    %{assigns: %{scope_change_confirm: scope_atom}} = socket)
      when not is_nil(scope_atom) do
    case Users.set_access_scope(socket.assigns.user, scope_atom, socket.assigns.subject,
                                  socket.assigns.remote_ip) do
      {:ok, updated} ->
        msg =
          case scope_atom do
            :all      -> "Access scope set to ALL — this user now bypasses L7 group checks."
            :limited  -> "Access scope reset to LIMITED — normal group checks apply."
          end

        {:noreply,
         socket
         |> assign(:user, updated)
         |> assign(:scope_change_confirm, nil)
         |> put_flash(:info, msg)}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:scope_change_confirm, nil)
         |> put_flash(:error, "Could not update access scope.")}
    end
  end

  def handle_event("delete_user", %{"user_id" => user_id}, socket) do
    if user_id == "#{socket.assigns.current_user.id}" do
      {:noreply,
       socket
       |> put_flash(:error, "Use the account section to delete your account.")}
    else
      {:ok, user} = Users.fetch_user_by_id(user_id, socket.assigns.subject)

      case Users.delete_user(user, socket.assigns.subject, socket.assigns.remote_ip) do
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

  # ── Template helpers (Phase U-Show-A) ───────────────────────────

  @doc "Last activity = whichever is newer: portal sign-in or VPN handshake."
  def last_activity(%{last_signed_in_at: sign_in, last_handshake: handshake}) do
    [sign_in, handshake]
    |> Enum.reject(&is_nil/1)
    |> case do
      []   -> nil
      list -> Enum.max(list, DateTime)
    end
  end

  def last_activity(_), do: nil

  def disabled?(%{disabled_at: %DateTime{}}), do: true
  def disabled?(_), do: false

  def mfa_state(%{mfa_count: 0}),               do: :none
  def mfa_state(%{mfa_count: nil}),             do: :none
  def mfa_state(%{mfa_last_used: nil}),          do: :unverified

  def mfa_state(%{mfa_last_used: %DateTime{} = ts}) do
    days = DateTime.diff(DateTime.utc_now(), ts, :day)
    if days <= @mfa_stale_days, do: :fresh, else: :stale
  end

  def mfa_state(_), do: :none

  def mfa_state_icon(:fresh),      do: "mdi-check-circle"
  def mfa_state_icon(:stale),      do: "mdi-alert-circle-outline"
  def mfa_state_icon(:unverified), do: "mdi-help-circle-outline"
  def mfa_state_icon(:none),       do: "mdi-minus-circle-outline"

  def mfa_state_class(:fresh),      do: "ng-user-mfa--fresh"
  def mfa_state_class(:stale),      do: "ng-user-mfa--stale"
  def mfa_state_class(:unverified), do: "ng-user-mfa--unverified"
  def mfa_state_class(:none),       do: "ng-user-mfa--none"

  def mfa_state_label(:fresh, ts),
    do: "MFA verified " <> relative_label(ts)

  def mfa_state_label(:stale, ts),
    do: "MFA " <> relative_label(ts) <> " ago — stale"

  def mfa_state_label(:unverified, _),
    do: "MFA enrolled · never verified"

  def mfa_state_label(:none, _),
    do: "No MFA factor"

  def relative_label(nil), do: "—"

  def relative_label(%DateTime{} = ts) do
    diff = DateTime.diff(DateTime.utc_now(), ts, :second)

    cond do
      diff < 60      -> "just now"
      diff < 3600    -> "#{div(diff, 60)}m ago"
      diff < 86_400  -> "#{div(diff, 3600)}h ago"
      true            -> "#{div(diff, 86_400)}d ago"
    end
  end
end
