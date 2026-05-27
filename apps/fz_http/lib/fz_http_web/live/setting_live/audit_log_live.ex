defmodule FzHttpWeb.SettingLive.AuditLog do
  @moduledoc """
  Paginated, filterable view of the audit log.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.{AuditLogs, Config}

  @page_size AuditLogs.page_size()

  @categories [
    {"All Events", ""},
    {"Authentication", "auth"},
    {"Users", "user"},
    {"Config", "config"},
    {"Devices", "device"},
    {"Rules", "rule"},
    {"VPN", "vpn"}
  ]

  @results [
    {"All Results", ""},
    {"Success", "success"},
    {"Failure", "failure"}
  ]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Audit Log")
      |> assign(:page_subtitle, "Immutable record of all security-relevant events.")
      |> assign(:category, "")
      |> assign(:result_filter, "")
      |> assign(:page, 1)
      |> assign(:categories, @categories)
      |> assign(:results, @results)
      |> assign(:retention_days, Config.fetch_config!(:audit_log_retention_days))
      |> load_logs()

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("update_retention", %{"retention" => %{"days" => days_str}}, socket) do
    days = String.to_integer(days_str)

    case Config.update_config(Config.fetch_db_config!(), %{audit_log_retention_days: days}, socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, _config} ->
        socket =
          socket
          |> assign(:retention_days, days)
          |> put_flash(:info, "Retention policy updated to #{days} days.")

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Invalid retention value (must be 1–3650 days).")}
    end
  end

  def handle_event("filter", %{"category" => category, "result" => result}, socket) do
    socket =
      socket
      |> assign(:category, category)
      |> assign(:result_filter, result)
      |> assign(:page, 1)
      |> load_logs()

    {:noreply, socket}
  end

  def handle_event("prev_page", _, socket) do
    page = max(1, socket.assigns.page - 1)
    {:noreply, socket |> assign(:page, page) |> load_logs()}
  end

  def handle_event("next_page", _, socket) do
    page = socket.assigns.page + 1
    {:noreply, socket |> assign(:page, page) |> load_logs()}
  end

  # ── Helpers ─────────────────────────────────────────────────────

  def action_category(action) do
    action |> String.split(".") |> List.first()
  end

  def format_actor(nil, nil), do: "System"
  def format_actor(nil, email), do: email
  def format_actor(_id, email) when is_binary(email), do: email
  def format_actor(_id, _), do: "—"

  def target_parts(nil, _, _), do: nil
  def target_parts(type, _id, label) when is_binary(type), do: {type, label}
  def target_parts(_, _, _), do: nil

  # ── Private ──────────────────────────────────────────────────────

  defp load_logs(socket) do
    filters = base_filters(socket)
    logs = AuditLogs.list_logs([{:page, socket.assigns.page} | filters])
    total = AuditLogs.count_logs(filters)
    grand_total = AuditLogs.count_logs([])
    total_pages = max(1, ceil(total / @page_size))

    socket
    |> assign(:logs, logs)
    |> assign(:total, total)
    |> assign(:grand_total, grand_total)
    |> assign(:total_pages, total_pages)
  end

  defp base_filters(socket) do
    []
    |> maybe_add(:category, socket.assigns.category)
    |> maybe_add(:result, socket.assigns.result_filter)
  end

  defp maybe_add(filters, _key, ""), do: filters
  defp maybe_add(filters, key, value), do: [{key, value} | filters]

end
