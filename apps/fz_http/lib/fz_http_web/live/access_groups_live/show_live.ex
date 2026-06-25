defmodule FzHttpWeb.AccessGroupsLive.Show do
  @moduledoc """
  Detail page for one access group:
    * inline edit name + description
    * member roster with add (by email) and remove
    * delete the entire group (with confirm)
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{AccessGroups, Users, Repo}

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <- AccessGroups.fetch_group_by_id(id, socket.assigns.subject) do
      {:ok,
       socket
       |> assign(:show_delete_confirm, false)
       |> assign(:remove_member_confirm, nil)
       |> load_group_assigns(group)}
    else
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Group not found.")
         |> redirect(to: ~p"/access-groups")}
    end
  end

  def handle_event("show_delete_confirm", _, socket),
    do: {:noreply, assign(socket, :show_delete_confirm, true)}

  def handle_event("cancel_delete", _, socket),
    do: {:noreply, assign(socket, :show_delete_confirm, false)}

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  # ── Edit name / description ───────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("update", %{"group" => attrs}, socket) do
    case AccessGroups.update_group(socket.assigns.group, attrs, socket.assigns.subject,
                                    socket.assigns[:remote_ip]) do
      {:ok, group} ->
        {:noreply,
         socket
         |> load_group_assigns(group)
         |> put_flash(:info, "Group updated.")}

      {:error, cs} ->
        {:noreply, assign(socket, :changeset, cs)}
    end
  end

  def handle_event("validate", %{"group" => attrs}, socket) do
    cs =
      socket.assigns.group
      |> AccessGroups.change_group(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, cs)}
  end

  # ── Add / remove members ──────────────────────────────────────

  # `add_member` now accepts the user_id from a `<select>` of
  # candidate users (kept the email path as a fallback for any
  # external POST that still sends email — picks the right branch
  # via param shape).
  def handle_event("add_member", %{"user_id" => user_id}, socket)
      when is_binary(user_id) and user_id != "" do
    case Repo.get(Users.User, user_id) do
      nil  -> {:noreply, put_flash(socket, :error, "User not found.")}
      user -> add_user_to_group(socket, user)
    end
  end

  def handle_event("add_member", %{"email" => email}, socket) do
    email = String.trim(email)

    case Repo.get_by(Users.User, email: email) do
      nil  -> {:noreply, put_flash(socket, :error, "No user with email #{email}.")}
      user -> add_user_to_group(socket, user)
    end
  end

  defp add_user_to_group(socket, user) do
    case AccessGroups.add_member(socket.assigns.group, user, socket.assigns.subject,
                                  socket.assigns[:remote_ip]) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> load_group_assigns(socket.assigns.group)
         |> put_flash(:info, "#{user.email} added to #{socket.assigns.group.name}.")}

      {:error, cs} ->
        msg =
          cs
          |> errors_on_changeset()
          |> Enum.map(fn {f, msgs} -> "#{f}: #{Enum.join(msgs, ", ")}" end)
          |> Enum.join("; ")

        {:noreply, put_flash(socket, :error, "Could not add: #{msg}")}
    end
  end

  def handle_event("confirm_remove_member", %{"user-id" => user_id}, socket) do
    case Repo.get(Users.User, user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "User not found.")}

      user ->
        {:noreply, assign(socket, :remove_member_confirm, user)}
    end
  end

  def handle_event("cancel_remove_member", _, socket),
    do: {:noreply, assign(socket, :remove_member_confirm, nil)}

  def handle_event("remove_member", _params, %{assigns: %{remove_member_confirm: user}} = socket)
      when not is_nil(user) do
    case AccessGroups.remove_member(socket.assigns.group, user, socket.assigns.subject,
                                     socket.assigns[:remote_ip]) do
      {:ok, :removed} ->
        {:noreply,
         socket
         |> assign(:remove_member_confirm, nil)
         |> load_group_assigns(socket.assigns.group)
         |> put_flash(:info, "#{user.email} removed.")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:remove_member_confirm, nil)
         |> put_flash(:error, "Could not remove member.")}
    end
  end

  # ── Delete group ──────────────────────────────────────────────

  def handle_event("delete_group", _params, socket) do
    case AccessGroups.delete_group(socket.assigns.group, socket.assigns.subject,
                                    socket.assigns[:remote_ip]) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Group deleted.")
         |> push_redirect(to: ~p"/access-groups")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete group.")}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp load_group_assigns(socket, group) do
    group = Repo.preload(group, [memberships: [:user, :added_by]])
    member_ids = group.memberships |> Enum.map(& &1.user_id) |> MapSet.new()

    available_users =
      case Users.list_users(socket.assigns.subject) do
        {:ok, all_users} ->
          all_users
          |> Enum.reject(&MapSet.member?(member_ids, &1.id))
          |> Enum.sort_by(& &1.email)

        _ ->
          []
      end

    socket
    |> assign(:group, group)
    |> assign(:members, group.memberships)
    |> assign(:available_users, available_users)
    |> assign(:changeset, AccessGroups.change_group(group, %{}))
    |> assign(:page_title, "Group: #{group.name}")
  end

  defp errors_on_changeset(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
