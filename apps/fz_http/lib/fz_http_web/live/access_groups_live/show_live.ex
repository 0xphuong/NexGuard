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
      {:ok, load_group_assigns(socket, group)}
    else
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Group not found.")
         |> redirect(to: ~p"/access-groups")}
    end
  end

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

  def handle_event("add_member", %{"email" => email}, socket) do
    email = String.trim(email)

    case Repo.get_by(Users.User, email: email) do
      nil ->
        {:noreply, put_flash(socket, :error, "No user with email #{email}.")}

      user ->
        case AccessGroups.add_member(socket.assigns.group, user, socket.assigns.subject,
                                      socket.assigns[:remote_ip]) do
          {:ok, _membership} ->
            {:noreply,
             socket
             |> load_group_assigns(socket.assigns.group)
             |> put_flash(:info, "#{email} added to #{socket.assigns.group.name}.")}

          {:error, cs} ->
            msg =
              cs
              |> errors_on_changeset()
              |> Enum.map(fn {f, msgs} -> "#{f}: #{Enum.join(msgs, ", ")}" end)
              |> Enum.join("; ")

            {:noreply, put_flash(socket, :error, "Could not add: #{msg}")}
        end
    end
  end

  def handle_event("remove_member", %{"user-id" => user_id}, socket) do
    case Repo.get(Users.User, user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "User not found.")}

      user ->
        case AccessGroups.remove_member(socket.assigns.group, user, socket.assigns.subject,
                                         socket.assigns[:remote_ip]) do
          {:ok, :removed} ->
            {:noreply,
             socket
             |> load_group_assigns(socket.assigns.group)
             |> put_flash(:info, "#{user.email} removed.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not remove member.")}
        end
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

    socket
    |> assign(:group, group)
    |> assign(:members, group.memberships)
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
