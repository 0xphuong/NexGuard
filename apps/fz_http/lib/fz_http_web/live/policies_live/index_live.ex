defmodule FzHttpWeb.PoliciesLive.Index do
  @moduledoc """
  Admin-facing list of L3/L4 policies (server v3.3.0). Each row
  summarises a named policy + its rule count + user count. New
  policies land via a modal `:new` action; delete opens a styled
  in-app modal (matches Applications, Users, Access Groups).

  Coexists with the legacy `/rules` UI during the v3.3.x
  transition -- both surfaces read from `FzHttp.Events.set_rules/0`,
  which merges policy-derived + legacy per-user rules into the
  flat set fed to `FzWall.Server`.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{Policies, Repo}

  @page_title "Policies"
  @page_subtitle "Named egress policies -- create once, assign users, replace per-user firewall rules."

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    with {:ok, policies} <- Policies.list_policies(socket.assigns.subject),
         {:ok, default_policy} <- Policies.fetch_default_policy(socket.assigns.subject) do
      policies = decorate(policies)
      filters = default_filters()

      {:ok,
       socket
       |> assign(:all_policies, policies)
       |> assign(:policies, apply_filters(policies, filters))
       |> assign(:filters, filters)
       |> assign(:default_policy, default_policy)
       |> assign(:delete_confirm, nil)
       |> assign(:clear_default_confirm, false)
       |> assign(:page_title, @page_title)
       |> assign(:page_subtitle, @page_subtitle)}
    else
      {:error, _reason} ->
        # LiveView contract requires `{:ok, socket}` from mount --
        # returning `{:error, ...}` crashes with ArgumentError.
        # Redirect to Dashboard with a flash instead so an
        # unauthorized user sees a clean message instead of a 500.
        {:ok,
         socket
         |> put_flash(:error, "You don't have permission to view Policies.")
         |> redirect(to: "/dashboard")}
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
     |> assign(:policies, apply_filters(socket.assigns.all_policies, filters))}
  end

  def handle_event("reset_filters", _params, socket) do
    filters = default_filters()

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:policies, apply_filters(socket.assigns.all_policies, filters))}
  end

  # ── Delete with styled confirm modal ─────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    # Pull from the already-decorated list rather than
    # `Policies.fetch_policy_by_id/2`. The fetched row is a bare
    # `%Policy{}` without the `rule_count`/`user_count` merged
    # in by `decorate/1`, so the modal (which surfaces both
    # counts before the destructive action) would crash on a
    # KeyError. `all_policies` is trusted -- it already went
    # through authorisation at mount.
    case Enum.find(socket.assigns.all_policies, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Policy not found.")}

      policy ->
        {:noreply, assign(socket, :delete_confirm, policy)}
    end
  end

  def handle_event("cancel_delete", _, socket),
    do: {:noreply, assign(socket, :delete_confirm, nil)}

  def handle_event("delete", _params, %{assigns: %{delete_confirm: policy}} = socket)
      when not is_nil(policy) do
    case Policies.delete_policy(policy, socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, _} ->
        {:ok, policies} = Policies.list_policies(socket.assigns.subject)
        policies = decorate(policies)

        {:noreply,
         socket
         |> assign(:all_policies, policies)
         |> assign(:policies, apply_filters(policies, socket.assigns.filters))
         |> assign(:delete_confirm, nil)
         |> put_flash(:info, "Policy \"#{policy.name}\" deleted.")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:delete_confirm, nil)
         |> put_flash(:error, "Could not delete policy.")}
    end
  end

  # ── Default Policy ──────────────────────────────────────────────
  # v4.0.4: catch-all rule sits at the tail of the effective-rules
  # stream. UI is a single verdict selector -- allow/deny for all
  # users, all destinations (v4 + v6). Persisted as a normal Policy
  # row with `is_default = true`; emission adds the synthesised
  # 0.0.0.0/0 + ::/0 catch-all rules on top of whatever regular
  # policies emit.

  def handle_event("save_default", %{"default" => %{"action" => action}}, socket) do
    case Policies.upsert_default_policy(
           %{"default_action" => action},
           socket.assigns.subject,
           socket.assigns[:remote_ip]
         ) do
      {:ok, policy} ->
        {:noreply,
         socket
         |> assign(:default_policy, policy)
         |> put_flash(:info, "Default policy set to #{policy.default_action}.")}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Could not save default policy.")}
    end
  end

  def handle_event("confirm_clear_default", _, socket),
    do: {:noreply, assign(socket, :clear_default_confirm, true)}

  def handle_event("cancel_clear_default", _, socket),
    do: {:noreply, assign(socket, :clear_default_confirm, false)}

  def handle_event("clear_default", _params, socket) do
    case Policies.clear_default_policy(socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:default_policy, nil)
         |> assign(:clear_default_confirm, false)
         |> put_flash(:info, "Default policy cleared. Unmatched traffic now falls through to policy accept.")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:clear_default_confirm, false)
         |> put_flash(:error, "Could not clear default policy.")}
    end
  end

  # ── Template helpers ───────────────────────────────────────────

  def filters_active?(%{"search" => s}), do: s != ""

  defp default_filters, do: %{"search" => ""}

  defp apply_filters(policies, %{"search" => search}) do
    Enum.filter(policies, &match_search?(&1, search))
  end

  defp match_search?(_policy, ""), do: true

  defp match_search?(policy, query) do
    q = String.downcase(query)
    name = String.downcase(policy.name || "")
    desc = String.downcase(policy.description || "")

    String.contains?(name, q) or String.contains?(desc, q)
  end

  # Decorate list-items with a rule + user count. Two `SELECT
  # count(*) ... GROUP BY policy_id` queries stay O(policies) so
  # the list renders fast even at ~hundreds of policies. Two
  # separate queries -- Ecto's aggregate helpers don't compose
  # into a single GROUP BY cleanly across two tables.
  defp decorate(policies) do
    import Ecto.Query

    ids = Enum.map(policies, & &1.id)

    rule_counts =
      from(pr in FzHttp.Policies.PolicyRule,
        where: pr.policy_id in ^ids,
        group_by: pr.policy_id,
        select: {pr.policy_id, count(pr.id)}
      )
      |> Repo.all()
      |> Map.new()

    user_counts =
      from(up in FzHttp.Policies.UserPolicy,
        where: up.policy_id in ^ids,
        group_by: up.policy_id,
        select: {up.policy_id, count(up.user_id)}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(policies, fn p ->
      Map.merge(p, %{
        rule_count: Map.get(rule_counts, p.id, 0),
        user_count: Map.get(user_counts, p.id, 0)
      })
    end)
  end
end
