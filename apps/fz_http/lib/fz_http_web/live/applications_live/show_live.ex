defmodule FzHttpWeb.ApplicationsLive.Show do
  @moduledoc """
  Detail page for one application. Wave 3b-1 ships the read-only
  detail + edit-via-modal + delete. The required-groups picker
  (Wave 3b-3) and L7 rules editor (Wave 3c) plug into separate cards
  on this page in later waves.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{Applications, AccessGroups}

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    case Applications.fetch_application_by_id(id, socket.assigns.subject) do
      {:ok, app} ->
        {:ok,
         socket
         |> assign(:application, app)
         |> assign(:delete_confirm, false)
         |> assign(:remove_group_confirm, nil)
         |> assign(:page_title, app.name)
         |> load_groups_assigns(app)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Application not found.")
         |> redirect(to: ~p"/applications")}
    end
  end

  # Split `allowed_groups` (already linked) from `available_groups`
  # (everything else) so the picker only shows what's addable. Empty
  # `available_groups` triggers the "this app is allowed for every
  # existing group" hint in the template.
  defp load_groups_assigns(socket, app) do
    {allowed, available} =
      case AccessGroups.list_groups(socket.assigns.subject) do
        {:ok, all_groups} ->
          allowed_ids = MapSet.new(app.allowed_groups, & &1.id)
          Enum.split_with(all_groups, &MapSet.member?(allowed_ids, &1.id))

        _ ->
          {[], []}
      end

    socket
    |> assign(:allowed_groups, allowed)
    |> assign(:available_groups, available)
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :tab, tab_for_action(socket.assigns.live_action))}
  end

  # Map the URL-driven live_action onto a single :tab atom. The :edit
  # action opens a modal overlay — the tab underneath defaults to
  # :overview because that's what `/applications/:id/edit` patches
  # from. Bookmarkable URLs land on the right tab directly.
  defp tab_for_action(:policy), do: :policy
  defp tab_for_action(:groups), do: :groups
  defp tab_for_action(:danger), do: :danger
  defp tab_for_action(_),       do: :overview

  @impl Phoenix.LiveView
  def handle_event("confirm_delete", _, socket),
    do: {:noreply, assign(socket, :delete_confirm, true)}

  def handle_event("cancel_delete", _, socket),
    do: {:noreply, assign(socket, :delete_confirm, false)}

  def handle_event("delete", _, socket) do
    case Applications.delete_application(socket.assigns.application, socket.assigns.subject,
                                          socket.assigns[:remote_ip]) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Application deleted.")
         |> push_redirect(to: ~p"/applications")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:delete_confirm, false)
         |> put_flash(:error, "Could not delete application.")}
    end
  end

  # ── Allowed-groups CRUD ────────────────────────────────────────

  def handle_event("add_allowed_group", %{"group_id" => group_id}, socket) do
    with {:ok, group} <- AccessGroups.fetch_group_by_id(group_id, socket.assigns.subject),
         {:ok, _link} <- Applications.add_allowed_group(socket.assigns.application, group,
                           socket.assigns.subject, socket.assigns[:remote_ip]),
         {:ok, app} <- Applications.fetch_application_by_id(socket.assigns.application.id,
                         socket.assigns.subject) do
      {:noreply,
       socket
       |> assign(:application, app)
       |> load_groups_assigns(app)
       |> put_flash(:info, "#{group.name} is now allowed for this app.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not add group.")}
    end
  end

  def handle_event("confirm_remove_group", %{"group_id" => group_id}, socket) do
    case AccessGroups.fetch_group_by_id(group_id, socket.assigns.subject) do
      {:ok, group} -> {:noreply, assign(socket, :remove_group_confirm, group)}
      {:error, _}  -> {:noreply, put_flash(socket, :error, "Group not found.")}
    end
  end

  def handle_event("cancel_remove_group", _, socket),
    do: {:noreply, assign(socket, :remove_group_confirm, nil)}

  def handle_event("remove_allowed_group", _params,
                    %{assigns: %{remove_group_confirm: group}} = socket)
      when not is_nil(group) do
    case Applications.remove_allowed_group(socket.assigns.application, group,
                                             socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, :removed} ->
        {:ok, app} = Applications.fetch_application_by_id(socket.assigns.application.id,
                       socket.assigns.subject)

        {:noreply,
         socket
         |> assign(:application, app)
         |> assign(:remove_group_confirm, nil)
         |> load_groups_assigns(app)
         |> put_flash(:info, "#{group.name} removed from allowed list.")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:remove_group_confirm, nil)
         |> put_flash(:error, "Could not remove group.")}
    end
  end

  # ── L7 rules editor ────────────────────────────────────────────

  def handle_event("add_rule", params, socket) do
    rule = build_rule_from_form(params)
    new_rules = (socket.assigns.application.l7_rules || []) ++ [rule]
    persist_rules(socket, new_rules, "Rule added.")
  end

  def handle_event("delete_rule", %{"index" => idx}, socket) do
    idx = String.to_integer(idx)
    new_rules = List.delete_at(socket.assigns.application.l7_rules || [], idx)
    persist_rules(socket, new_rules, "Rule removed.")
  end

  def handle_event("move_rule_up", %{"index" => idx}, socket) do
    idx = String.to_integer(idx)
    rules = socket.assigns.application.l7_rules || []

    if idx > 0 do
      persist_rules(socket, swap(rules, idx, idx - 1), "Rule moved up.")
    else
      {:noreply, socket}
    end
  end

  def handle_event("move_rule_down", %{"index" => idx}, socket) do
    idx = String.to_integer(idx)
    rules = socket.assigns.application.l7_rules || []

    if idx < length(rules) - 1 do
      persist_rules(socket, swap(rules, idx, idx + 1), "Rule moved down.")
    else
      {:noreply, socket}
    end
  end

  defp build_rule_from_form(params) do
    methods =
      ~w[GET POST PUT DELETE PATCH]
      |> Enum.filter(&Map.has_key?(params, "method_#{&1}"))

    require_groups =
      params
      |> Enum.filter(fn {k, _} -> String.starts_with?(k, "rg_") end)
      |> Enum.map(fn {_, name} -> name end)
      |> Enum.reject(&(&1 == "" or is_nil(&1)))

    path = params["path_prefix"] |> to_string() |> String.trim()
    mfa  = params["require_mfa_age_seconds"] |> to_string() |> String.trim()

    base = %{"action" => params["action"] || "deny"}

    base
    |> put_if(methods != [], "method", methods)
    |> put_if(path != "", "path_prefix", path)
    |> put_if(require_groups != [], "require_groups", require_groups)
    |> put_if(mfa != "", "require_mfa_age_seconds", parse_int(mfa, 0))
  end

  defp put_if(map, true, key, value),  do: Map.put(map, key, value)
  defp put_if(map, false, _, _),       do: map

  defp parse_int(s, default) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> default
    end
  end

  defp swap(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)
    list
    |> List.replace_at(i, b)
    |> List.replace_at(j, a)
  end

  defp persist_rules(socket, new_rules, success_msg) do
    case Applications.update_application(
           socket.assigns.application,
           %{"l7_rules" => new_rules},
           socket.assigns.subject,
           socket.assigns[:remote_ip]
         ) do
      {:ok, app} ->
        {:noreply,
         socket
         |> assign(:application, app)
         |> put_flash(:info, success_msg)}

      {:error, cs} ->
        msg =
          cs
          |> Ecto.Changeset.traverse_errors(fn {m, _} -> m end)
          |> Map.values()
          |> List.flatten()
          |> Enum.join("; ")

        {:noreply, put_flash(socket, :error, "Could not save: #{msg}")}
    end
  end

  def handle_event("toggle_enabled", _, socket) do
    target = !socket.assigns.application.enabled

    case Applications.set_application_enabled(socket.assigns.application, target,
                                                socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, app} ->
        msg = if app.enabled, do: "Application enabled.", else: "Application disabled."
        {:noreply, socket |> assign(:application, app) |> put_flash(:info, msg)}

      {:error, %Ecto.Changeset{} = cs} ->
        # Most likely "cannot enable without an L7 rule" — surface verbatim.
        msg =
          cs
          |> Ecto.Changeset.traverse_errors(fn {m, _} -> m end)
          |> Map.values()
          |> List.flatten()
          |> Enum.join("; ")

        {:noreply, put_flash(socket, :error, "Could not toggle: #{msg}")}
    end
  end
end
