defmodule FzHttpWeb.UserLive.Index do
  @moduledoc """
  Admin /users index.

  Phase U-A (shipped): stats strip, MFA freshness column, last
  activity (max sign-in / handshake), disabled row styling.

  Phase U-B (this): search by email + 3 filter chips (Role / MFA /
  Status). Filtering runs in memory over the already-loaded list —
  user counts are small (typically <100) and the SQL aggregate
  hydrate that drives this page is the expensive bit; the filter
  itself is microseconds.

  Phase U-C (this): bulk select column, sticky toolbar, three
  actions (Disable / Enable / Delete). Reuses the visual pattern
  shipped for /devices in v3.0.4.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Users

  @page_title "Users"
  @active_window_secs 86_400
  @mfa_stale_days 30

  @default_filters %{
    "search" => "",
    "role"   => "",       # "" = all, "admin", "unprivileged"
    "mfa"    => "",       # "" = any, "enrolled", "none"
    "status" => "active"  # "active" (default), "all", "disabled"
  }

  @role_options [{"All roles", ""}, {"Admin", "admin"}, {"Unprivileged", "unprivileged"}]
  @mfa_options [{"Any MFA", ""}, {"MFA enrolled", "enrolled"}, {"No MFA", "none"}]
  @status_options [{"Active only", "active"}, {"All users", "all"}, {"Disabled only", "disabled"}]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    with {:ok, users} <- Users.list_users(socket.assigns.subject, hydrate: [:index]) do
      socket =
        socket
        |> assign(:all_users, users)
        |> assign(:stats, compute_stats(users))
        |> assign(:filters, @default_filters)
        |> assign(:role_options, @role_options)
        |> assign(:mfa_options, @mfa_options)
        |> assign(:status_options, @status_options)
        |> assign(:selected, MapSet.new())
        |> assign(:bulk_confirm, nil)
        |> assign(:changeset, Users.change_user())
        |> assign(:page_title, @page_title)
        |> apply_filters()

      {:ok, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  # ── Filter events ──────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("filter", %{"filters" => filters}, socket) do
    new_filters = Map.merge(socket.assigns.filters, filters)

    {:noreply,
     socket
     |> assign(:filters, new_filters)
     |> assign(:selected, MapSet.new())
     |> apply_filters()}
  end

  def handle_event("reset_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:filters, @default_filters)
     |> assign(:selected, MapSet.new())
     |> apply_filters()}
  end

  # ── Bulk selection ─────────────────────────────────────────────

  def handle_event("toggle_select", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected, toggle_set(socket.assigns.selected, id))}
  end

  def handle_event("toggle_select_all", _params, socket) do
    selected =
      if all_visible_selected?(socket) do
        MapSet.new()
      else
        socket.assigns.users |> Enum.map(& &1.id) |> MapSet.new()
      end

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("clear_selection", _params, socket),
    do: {:noreply, assign(socket, :selected, MapSet.new())}

  # ── Bulk operations ────────────────────────────────────────────

  def handle_event("bulk_disable", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected)

    result =
      Users.bulk_disable(ids, socket.assigns.subject, socket.assigns[:remote_ip])

    {:noreply, after_bulk(socket, "Disable", result)}
  end

  def handle_event("bulk_enable", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected)

    result =
      Users.bulk_enable(ids, socket.assigns.subject, socket.assigns[:remote_ip])

    {:noreply, after_bulk(socket, "Enable", result)}
  end

  def handle_event("confirm_bulk_delete", _params, socket),
    do: {:noreply, assign(socket, :bulk_confirm, :delete)}

  def handle_event("cancel_bulk_delete", _params, socket),
    do: {:noreply, assign(socket, :bulk_confirm, nil)}

  def handle_event("bulk_delete", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected)

    result =
      Users.bulk_delete(ids, socket.assigns.subject, socket.assigns[:remote_ip])

    {:noreply, after_bulk(socket, "Delete", result, clear_confirm: true)}
  end

  # ── Helpers — filtering + selection ────────────────────────────

  defp apply_filters(socket) do
    filtered = filter_users(socket.assigns.all_users, socket.assigns.filters)
    assign(socket, :users, filtered)
  end

  defp filter_users(users, filters) do
    needle = String.downcase(filters["search"] || "")

    users
    |> Enum.filter(fn user ->
      matches_search?(user, needle) and
        matches_role?(user, filters["role"]) and
        matches_mfa?(user, filters["mfa"]) and
        matches_status?(user, filters["status"])
    end)
  end

  defp matches_search?(_user, ""), do: true

  defp matches_search?(%{email: email}, needle) when is_binary(email),
    do: String.contains?(String.downcase(email), needle)

  defp matches_search?(_, _), do: false

  defp matches_role?(_user, ""), do: true

  defp matches_role?(%{role: role}, want) when is_binary(want) do
    to_string(role) == want
  end

  defp matches_role?(_, _), do: true

  defp matches_mfa?(_user, ""),         do: true
  defp matches_mfa?(%{mfa_count: c}, "enrolled"), do: c > 0
  defp matches_mfa?(%{mfa_count: c}, "none"),     do: c == 0
  defp matches_mfa?(_, _), do: true

  defp matches_status?(%{disabled_at: nil},        "active"),   do: true
  defp matches_status?(%{disabled_at: nil},        "disabled"), do: false
  defp matches_status?(%{disabled_at: %DateTime{}}, "active"),   do: false
  defp matches_status?(%{disabled_at: %DateTime{}}, "disabled"), do: true
  defp matches_status?(_, _),                                    do: true

  defp toggle_set(set, v) do
    if MapSet.member?(set, v), do: MapSet.delete(set, v), else: MapSet.put(set, v)
  end

  defp all_visible_selected?(socket) do
    socket.assigns.users != [] and
      Enum.all?(socket.assigns.users, &MapSet.member?(socket.assigns.selected, &1.id))
  end

  defp after_bulk(socket, verb, %{ok: ok, skip: skip, error: error}, opts \\ []) do
    {:ok, fresh} =
      Users.list_users(socket.assigns.subject, hydrate: [:index])

    flash_msg  = build_flash_msg(verb, ok, skip, error)
    flash_kind = if error > 0, do: :error, else: :info

    socket
    |> assign(:all_users, fresh)
    |> assign(:stats, compute_stats(fresh))
    |> assign(:selected, MapSet.new())
    |> then(fn s ->
      if Keyword.get(opts, :clear_confirm, false),
        do: assign(s, :bulk_confirm, nil),
        else: s
    end)
    |> apply_filters()
    |> put_flash(flash_kind, flash_msg)
  end

  defp build_flash_msg(verb, ok, 0, 0),    do: "#{verb}d #{ok} user(s)."
  defp build_flash_msg(verb, ok, skip, 0), do: "#{verb}d #{ok} · skipped #{skip} (already in target state)."
  defp build_flash_msg(verb, ok, skip, error),
    do: "#{verb}: #{ok} ok · #{skip} skipped · #{error} failed."

  # Public so the template can read it.
  def selection_count(set), do: MapSet.size(set)

  # ── Stats strip ────────────────────────────────────────────────

  defp compute_stats(users) do
    now = DateTime.utc_now()
    total = length(users)

    %{
      total:        total,
      active_24h:   Enum.count(users, &active_within?(&1, now, @active_window_secs)),
      mfa_pct:      pct(Enum.count(users, &(&1.mfa_count > 0)), total),
      admin_count:  Enum.count(users, &(&1.role == :admin)),
      break_glass:  Enum.count(users, &(&1.access_scope == :all))
    }
  end

  defp active_within?(user, now, window_secs) do
    last = last_activity(user)
    not is_nil(last) and DateTime.diff(now, last, :second) <= window_secs
  end

  defp pct(_, 0), do: 0
  defp pct(part, total), do: round(part / total * 100)

  # ── Template helpers ───────────────────────────────────────────

  @doc """
  Last activity = whichever is newer between portal sign-in and
  any device handshake.
  """
  def last_activity(%{last_signed_in_at: sign_in, last_handshake: handshake}) do
    [sign_in, handshake]
    |> Enum.reject(&is_nil/1)
    |> case do
      []   -> nil
      list -> Enum.max(list, DateTime)
    end
  end

  def mfa_state(%{mfa_count: 0}),               do: :none
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

  def mfa_state_class(:fresh),      do: "ng-mfa-cell--fresh"
  def mfa_state_class(:stale),      do: "ng-mfa-cell--stale"
  def mfa_state_class(:unverified), do: "ng-mfa-cell--unverified"
  def mfa_state_class(:none),       do: "ng-mfa-cell--none"

  def relative_label(nil), do: "—"

  def relative_label(%DateTime{} = ts) do
    diff = DateTime.diff(DateTime.utc_now(), ts, :second)

    cond do
      diff < 60      -> "now"
      diff < 3600    -> "#{div(diff, 60)}m"
      diff < 86_400  -> "#{div(diff, 3600)}h"
      true            -> "#{div(diff, 86_400)}d"
    end
  end

  def disabled?(%{disabled_at: %DateTime{}}), do: true
  def disabled?(_), do: false

  def filters_active?(filters) do
    filters["search"] != "" or
      filters["role"]   != "" or
      filters["mfa"]    != "" or
      filters["status"] != "active"
  end
end
