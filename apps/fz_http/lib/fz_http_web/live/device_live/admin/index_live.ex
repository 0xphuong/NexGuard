defmodule FzHttpWeb.DeviceLive.Admin.Index do
  @moduledoc """
  Admin-facing device list. Bulk actions (UI-8): admins routinely
  approve N pending devices in a row — each click round-tripping
  through `confirm → mutate → re-render` is operational tax. The
  bulk toolbar appears when any row is selected and dispatches a
  single context call that iterates + audits per-row (so the audit
  trail stays row-level, not "bulk").
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
      devices =
        devices
        |> Repo.preload(:user)
        |> Enum.sort_by(& &1.user_id)

      socket =
        socket
        |> assign(:devices, devices)
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

  # ── Selection ──────────────────────────────────────────────────

  @impl Phoenix.LiveView
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
    devices = devices |> Repo.preload(:user) |> Enum.sort_by(& &1.user_id)

    flash_msg = build_flash_msg(verb, ok, skip, error)
    flash_kind = if error > 0, do: :error, else: :info

    socket
    |> assign(:devices, devices)
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

  # Public so the template can read it.
  def selection_count(set), do: MapSet.size(set)
end
