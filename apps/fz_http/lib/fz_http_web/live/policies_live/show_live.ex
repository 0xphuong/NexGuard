defmodule FzHttpWeb.PoliciesLive.Show do
  @moduledoc """
  Detail page for one policy. Split into four URL-addressable tabs
  (`:overview`, `:rules`, `:users`, `:danger`):

    * Overview -- read + inline edit of name / description /
      default_action.
    * Rules -- table of `policy_rules`; add/delete inline. Uses the
      same shape as legacy `FzHttp.Rules.Rule` so the destination /
      port_type / port_range validators + INET / Int4Range casts
      surface identical UX to admins already familiar with the
      legacy Rules page.
    * Users -- assign / unassign users via a `<select>` of
      candidates. Idempotent add (double-click no-ops).
    * Danger -- delete the whole policy (cascades to rules +
      assignments via the migration's `on_delete: :delete_all`).
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{Policies, Users, Repo}
  alias FzHttp.Policies.{Policy, PolicyRule}

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    case Policies.fetch_policy_by_id(id, socket.assigns.subject) do
      {:ok, policy} ->
        {:ok,
         socket
         |> assign(:show_delete_confirm, false)
         |> assign(:remove_user_confirm, nil)
         |> assign(:remove_rule_confirm, nil)
         |> assign(:bulk_add_confirm, false)
         |> assign(:tab, tab_for_action(socket.assigns[:live_action]))
         |> load_policy_assigns(policy)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Policy not found.")
         |> redirect(to: ~p"/policies")}

      {:error, _reason} ->
        # Missing permissions or other error -- LiveView contract
        # requires {:ok, socket}, so redirect with a flash instead
        # of returning {:error, ...} which crashes the channel.
        {:ok,
         socket
         |> put_flash(:error, "You don't have permission to view this policy.")
         |> redirect(to: "/dashboard")}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :tab, tab_for_action(socket.assigns.live_action))}
  end

  defp tab_for_action(:rules),    do: :rules
  defp tab_for_action(:users),    do: :users
  defp tab_for_action(:danger),   do: :danger
  defp tab_for_action(:show),     do: :overview
  defp tab_for_action(:overview), do: :overview
  defp tab_for_action(_),         do: :overview

  # ── Confirmation modals ───────────────────────────────────────

  def handle_event("show_delete_confirm", _, socket),
    do: {:noreply, assign(socket, :show_delete_confirm, true)}

  def handle_event("cancel_delete", _, socket),
    do: {:noreply, assign(socket, :show_delete_confirm, false)}

  def handle_event("confirm_remove_user", %{"user-id" => user_id}, socket) do
    case Repo.get(Users.User, user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "User not found.")}

      user ->
        {:noreply, assign(socket, :remove_user_confirm, user)}
    end
  end

  def handle_event("cancel_remove_user", _, socket),
    do: {:noreply, assign(socket, :remove_user_confirm, nil)}

  def handle_event("confirm_remove_rule", %{"rule-id" => rule_id}, socket) do
    case Enum.find(socket.assigns.rules, &(&1.id == rule_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Rule not found.")}

      rule ->
        {:noreply, assign(socket, :remove_rule_confirm, rule)}
    end
  end

  def handle_event("cancel_remove_rule", _, socket),
    do: {:noreply, assign(socket, :remove_rule_confirm, nil)}

  # ── Edit policy metadata ───────────────────────────────────────

  def handle_event("update", %{"policy" => attrs}, socket) do
    case Policies.update_policy(
           socket.assigns.policy,
           attrs,
           socket.assigns.subject,
           socket.assigns[:remote_ip]
         ) do
      {:ok, policy} ->
        {:noreply,
         socket
         |> load_policy_assigns(policy)
         |> put_flash(:info, "Policy updated.")}

      {:error, cs} ->
        {:noreply, assign(socket, :changeset, cs)}
    end
  end

  def handle_event("validate", %{"policy" => attrs}, socket) do
    cs =
      socket.assigns.policy
      |> Policies.change_policy(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, cs)}
  end

  # ── Add / delete rules ────────────────────────────────────────

  def handle_event("validate_rule", %{"rule" => attrs}, socket) do
    attrs = Map.put(attrs, "policy_id", socket.assigns.policy.id)

    cs =
      attrs
      |> Policies.new_policy_rule()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :rule_changeset, cs)}
  end

  def handle_event("add_rule", %{"rule" => attrs}, socket) do
    attrs =
      attrs
      |> Map.put("policy_id", socket.assigns.policy.id)
      |> normalize_port_fields()

    case Policies.create_policy_rule(attrs, socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> load_policy_assigns(socket.assigns.policy)
         |> put_flash(:info, "Rule added.")}

      {:error, cs} ->
        {:noreply, assign(socket, :rule_changeset, cs)}
    end
  end

  def handle_event(
        "remove_rule",
        _params,
        %{assigns: %{remove_rule_confirm: rule}} = socket
      )
      when not is_nil(rule) do
    case Policies.delete_policy_rule(rule, socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:remove_rule_confirm, nil)
         |> load_policy_assigns(socket.assigns.policy)
         |> put_flash(:info, "Rule removed.")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:remove_rule_confirm, nil)
         |> put_flash(:error, "Could not remove rule.")}
    end
  end

  # ── Add / remove users ────────────────────────────────────────

  def handle_event("add_user", %{"user_id" => user_id}, socket)
      when is_binary(user_id) and user_id != "" do
    case Policies.add_user_to_policy(
           socket.assigns.policy.id,
           user_id,
           socket.assigns.subject,
           socket.assigns[:remote_ip]
         ) do
      {:ok, :assigned} ->
        user = Repo.get(Users.User, user_id)

        {:noreply,
         socket
         |> load_policy_assigns(socket.assigns.policy)
         |> put_flash(:info, "#{(user && user.email) || "User"} assigned.")}

      {:ok, :already_assigned} ->
        {:noreply, put_flash(socket, :info, "User is already in this policy.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not add user.")}
    end
  end

  def handle_event("add_user", %{"user_id" => ""}, socket), do: {:noreply, socket}

  # Bulk-assign uses an in-app modal so admins see the count they're
  # about to affect (10 vs 100 vs 1000) and can cancel with Escape --
  # OS-native `data-confirm` prompts a plain browser dialog which
  # looks out-of-place next to the styled delete modals.
  def handle_event("confirm_add_all_users", _, socket),
    do: {:noreply, assign(socket, :bulk_add_confirm, true)}

  def handle_event("cancel_bulk_add", _, socket),
    do: {:noreply, assign(socket, :bulk_add_confirm, false)}

  def handle_event("add_all_users", _params, socket) do
    case Policies.add_all_users_to_policy(
           socket.assigns.policy.id,
           socket.assigns.subject,
           socket.assigns[:remote_ip]
         ) do
      {:ok, 0} ->
        {:noreply,
         socket
         |> assign(:bulk_add_confirm, false)
         |> put_flash(:info, "All users are already assigned.")}

      {:ok, count} ->
        {:noreply,
         socket
         |> assign(:bulk_add_confirm, false)
         |> load_policy_assigns(socket.assigns.policy)
         |> put_flash(:info, "Assigned #{count} user#{if count == 1, do: "", else: "s"}.")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:bulk_add_confirm, false)
         |> put_flash(:error, "Could not bulk-assign users.")}
    end
  end

  def handle_event(
        "remove_user",
        _params,
        %{assigns: %{remove_user_confirm: user}} = socket
      )
      when not is_nil(user) do
    case Policies.remove_user_from_policy(
           socket.assigns.policy.id,
           user.id,
           socket.assigns.subject,
           socket.assigns[:remote_ip]
         ) do
      {:ok, _count} ->
        {:noreply,
         socket
         |> assign(:remove_user_confirm, nil)
         |> load_policy_assigns(socket.assigns.policy)
         |> put_flash(:info, "#{user.email} removed.")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:remove_user_confirm, nil)
         |> put_flash(:error, "Could not remove user.")}
    end
  end

  # ── Delete policy ─────────────────────────────────────────────

  def handle_event("delete_policy", _params, socket) do
    case Policies.delete_policy(
           socket.assigns.policy,
           socket.assigns.subject,
           socket.assigns[:remote_ip]
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Policy deleted.")
         |> push_redirect(to: ~p"/policies")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete policy.")}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────

  # Empty strings from the form should be nil for port_type /
  # port_range so the changeset can enforce the "both or neither"
  # constraint. Also convert port_range from "80-443" text to the
  # `%Postgrex.Range{}`-friendly shape the Int4Range cast expects.
  defp normalize_port_fields(attrs) do
    attrs
    |> Map.update("port_type", nil, &empty_to_nil/1)
    |> Map.update("port_range", nil, &empty_to_nil/1)
  end

  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(v), do: v

  defp load_policy_assigns(socket, policy) do
    # `force: true` mirrors the pattern in AccessGroupsLive.Show --
    # without it Repo.preload is a no-op on already-loaded assocs,
    # and Add/Remove wouldn't reflect fresh state on re-render.
    policy = Repo.preload(policy, [:rules, :users], force: true)

    assigned_user_ids = policy.users |> Enum.map(& &1.id) |> MapSet.new()

    available_users =
      case Users.list_users(socket.assigns.subject) do
        {:ok, all_users} ->
          all_users
          |> Enum.reject(&MapSet.member?(assigned_user_ids, &1.id))
          |> Enum.sort_by(& &1.email)

        _ ->
          []
      end

    socket
    |> assign(:policy, policy)
    # v4.1.0: sort by (priority ASC, inserted_at ASC) so the
    # rules table reads top-down in evaluation order -- matches
    # what fz_wall actually applies to nftables.
    |> assign(:rules, Enum.sort_by(policy.rules, &{&1.priority, &1.inserted_at}))
    |> assign(:users, Enum.sort_by(policy.users, & &1.email))
    |> assign(:available_users, available_users)
    |> assign(:changeset, Policies.change_policy(policy, %{}))
    |> assign(:rule_changeset,
      Policies.new_policy_rule(%{
        "policy_id" => policy.id,
        "action" => "accept",
        "priority" => 100
      }))
    |> assign(:page_title, "Policy: #{policy.name}")
  end
end
