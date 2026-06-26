defmodule FzHttpWeb.DeviceLive.Admin.Index do
  @moduledoc """
  Admin-facing device list. Bulk actions (UI-8): admins routinely
  approve N pending devices in a row — each click round-tripping
  through `confirm → mutate → re-render` is operational tax. The
  bulk toolbar appears when any row is selected and dispatches a
  single context call that iterates + audits per-row (so the audit
  trail stays row-level, not "bulk").

  D-Idx-A/B/C (v3.0.9):
    * Stats strip (Total · Pending · Connected · Stale) above the
      table so the security-critical Pending count surfaces without
      scrolling.
    * Filter bar — search by device or user email, plus chips for
      `status` (Pending/Approved) and `connection` (Connected/
      Recent/Idle/Stale/Never).
    * Pending banner that one-clicks the Pending filter when there
      are devices to triage.
    * Sort: pending first, then `latest_handshake DESC NULLS LAST`,
      so the admin's eye lands on what needs attention.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.{Devices, Repo}

  @page_title "All Devices"
  @page_subtitle """
  Each device corresponds to a WireGuard configuration for connecting to this NexGuard server.
  """

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    with {:ok, devices} <- Devices.list_devices(socket.assigns.subject) do
      devices = devices |> Repo.preload(:user) |> sort_devices()
      filters = default_filters()

      socket =
        socket
        |> assign(:all_devices, devices)
        |> assign(:devices, apply_filters(devices, filters))
        |> assign(:stats, compute_stats(devices))
        |> assign(:filters, filters)
        |> assign(:status_options, status_options())
        |> assign(:connection_options, connection_options())
        |> assign(:selected, MapSet.new())
        |> assign(:bulk_confirm, nil)
        |> assign(:page_subtitle, @page_subtitle)
        |> assign(:page_title, @page_title)

      {:ok, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  # ── Filters ─────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = Map.merge(socket.assigns.filters, params)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:devices, apply_filters(socket.assigns.all_devices, filters))
     # Selection cleared on filter change — otherwise the count
     # claims rows the admin can no longer see.
     |> assign(:selected, MapSet.new())}
  end

  def handle_event("reset_filters", _params, socket) do
    filters = default_filters()

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:devices, apply_filters(socket.assigns.all_devices, filters))
     |> assign(:selected, MapSet.new())}
  end

  # Banner shortcut: focus the table on pending devices in one click.
  def handle_event("filter_pending_only", _params, socket) do
    filters = Map.merge(default_filters(), %{"status" => "pending"})

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:devices, apply_filters(socket.assigns.all_devices, filters))
     |> assign(:selected, MapSet.new())}
  end

  # ── Selection ──────────────────────────────────────────────────

  def handle_event("toggle_select", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected, toggle(socket.assigns.selected, id))}
  end

  def handle_event("toggle_select_all", _params, socket) do
    selected =
      if all_visible_selected?(socket) do
        MapSet.new()
      else
        socket.assigns.devices |> Enum.map(& &1.id) |> MapSet.new()
      end

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected, MapSet.new())}
  end

  # ── Bulk operations ─────────────────────────────────────────────

  def handle_event("bulk_approve", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected)
    result = Devices.bulk_approve(ids, socket.assigns.subject, socket.assigns[:remote_ip])
    {:noreply, after_bulk(socket, "Approve", result)}
  end

  def handle_event("bulk_revoke", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected)
    result = Devices.bulk_revoke_approval(ids, socket.assigns.subject, socket.assigns[:remote_ip])
    {:noreply, after_bulk(socket, "Revoke", result)}
  end

  def handle_event("confirm_bulk_delete", _params, socket) do
    {:noreply, assign(socket, :bulk_confirm, :delete)}
  end

  def handle_event("cancel_bulk_delete", _params, socket) do
    {:noreply, assign(socket, :bulk_confirm, nil)}
  end

  def handle_event("bulk_delete", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected)
    result = Devices.bulk_delete(ids, socket.assigns.subject, socket.assigns[:remote_ip])
    {:noreply, after_bulk(socket, "Delete", result, clear_confirm: true)}
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp toggle(set, v) do
    if MapSet.member?(set, v), do: MapSet.delete(set, v), else: MapSet.put(set, v)
  end

  defp all_visible_selected?(socket) do
    socket.assigns.devices != [] and
      Enum.all?(socket.assigns.devices, &MapSet.member?(socket.assigns.selected, &1.id))
  end

  defp after_bulk(socket, verb, %{ok: ok, skip: skip, error: error}, opts \\ []) do
    {:ok, devices} = Devices.list_devices(socket.assigns.subject)
    devices = devices |> Repo.preload(:user) |> sort_devices()

    flash_msg = build_flash_msg(verb, ok, skip, error)
    flash_kind = if error > 0, do: :error, else: :info

    socket
    |> assign(:all_devices, devices)
    |> assign(:devices, apply_filters(devices, socket.assigns.filters))
    |> assign(:stats, compute_stats(devices))
    |> assign(:selected, MapSet.new())
    |> then(fn s ->
      if Keyword.get(opts, :clear_confirm, false),
        do: assign(s, :bulk_confirm, nil),
        else: s
    end)
    |> put_flash(flash_kind, flash_msg)
  end

  defp build_flash_msg(verb, ok, 0, 0),   do: "#{verb}d #{ok} device(s)."
  defp build_flash_msg(verb, ok, skip, 0), do: "#{verb}d #{ok} · skipped #{skip} (already in target state)."
  defp build_flash_msg(verb, ok, skip, error),
    do: "#{verb}: #{ok} ok · #{skip} skipped · #{error} failed."

  # Public for the template.
  def selection_count(set), do: MapSet.size(set)

  def filters_active?(%{"search" => s, "status" => st, "connection" => c}) do
    s != "" or st != "all" or c != "all"
  end

  # ── Filter state ───────────────────────────────────────────────

  defp default_filters do
    %{"search" => "", "status" => "all", "connection" => "all"}
  end

  defp status_options do
    [
      {"Status: All",     "all"},
      {"Pending",         "pending"},
      {"Approved",        "approved"}
    ]
  end

  defp connection_options do
    [
      {"Connection: Any",      "all"},
      {"Connected (≤3m)",      "connected"},
      {"Recent (≤24h)",        "recent"},
      {"Idle (≤30d)",          "idle"},
      {"Stale (>30d)",         "stale"},
      {"Never connected",      "never"}
    ]
  end

  defp apply_filters(devices, %{"search" => search, "status" => status, "connection" => conn}) do
    devices
    |> Enum.filter(&match_search?(&1, search))
    |> Enum.filter(&match_status?(&1, status))
    |> Enum.filter(&match_connection?(&1, conn))
  end

  defp match_search?(_d, ""), do: true

  defp match_search?(d, query) do
    q = String.downcase(query)
    name = String.downcase(d.name || "")
    email = String.downcase(get_in(d, [Access.key(:user), Access.key(:email)]) || "")

    String.contains?(name, q) or String.contains?(email, q)
  end

  defp match_status?(_d, "all"), do: true
  defp match_status?(d, status), do: d.status == status

  defp match_connection?(_d, "all"), do: true

  defp match_connection?(d, conn) do
    Atom.to_string(Devices.connection_state(d)) == conn
  end

  # Pending first, then most-recently active. Surfaces what needs
  # admin attention without a separate "Pending" subtable.
  defp sort_devices(devices) do
    Enum.sort_by(devices, fn d ->
      pending_rank = if d.status == "pending", do: 0, else: 1
      hs_rank =
        case d.latest_handshake do
          %DateTime{year: y} = ts when y >= 2000 -> -DateTime.to_unix(ts)
          _                                      -> 0
        end

      {pending_rank, hs_rank}
    end)
  end

  defp compute_stats(devices) do
    by_state = Enum.frequencies_by(devices, &Devices.connection_state/1)

    %{
      total:     length(devices),
      pending:   Map.get(by_state, :pending, 0),
      connected: Map.get(by_state, :connected, 0),
      stale:     Map.get(by_state, :stale, 0)
    }
  end
end
