defmodule FzHttpWeb.SettingLive.AuditLog do
  @moduledoc """
  Paginated, filterable view of the audit log.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.{AuditLogs, Config}

  @page_size AuditLogs.page_size()

  @categories [
    {"All Events",     ""},
    {"Authentication", "auth"},
    {"Users",          "user"},
    {"Devices",        "device"},
    {"VPN",            "vpn"},
    {"Rules (L3/L4)",  "rule"},
    {"Applications",   "application"},
    {"Access Groups",  "access_group"},
    {"L7 (signing)",   "l7"},
    {"TLS Library",    "tls_cert"},
    {"Org Settings",   "org_settings"},
    {"Config",         "config"}
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
      |> assign(:expanded, MapSet.new())
      |> load_logs()

    {:ok, socket}
  end

  # Expand/collapse a row to reveal its metadata diff. Per-session
  # state lives in a MapSet on the socket — refresh clears it, which
  # is the right call (filter/page change shouldn't preserve which
  # rows were open under a different result set).
  @impl Phoenix.LiveView
  def handle_event("toggle_row", %{"id" => id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, id) do
        MapSet.delete(socket.assigns.expanded, id)
      else
        MapSet.put(socket.assigns.expanded, id)
      end

    {:noreply, assign(socket, :expanded, expanded)}
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
      |> assign(:expanded, MapSet.new())
      |> load_logs()

    {:noreply, socket}
  end

  def handle_event("prev_page", _, socket) do
    page = max(1, socket.assigns.page - 1)
    {:noreply, socket |> assign(:page, page) |> assign(:expanded, MapSet.new()) |> load_logs()}
  end

  def handle_event("next_page", _, socket) do
    page = socket.assigns.page + 1
    {:noreply, socket |> assign(:page, page) |> assign(:expanded, MapSet.new()) |> load_logs()}
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

  # ── Metadata viewer helpers ─────────────────────────────────────

  @doc "True when a row has any metadata worth expanding to display."
  def has_metadata?(nil), do: false
  def has_metadata?(m) when is_map(m), do: map_size(m) > 0
  def has_metadata?(_), do: false

  @doc "Open/closed state for a given row id."
  def expanded?(set, id), do: MapSet.member?(set, id)

  @doc """
  Classify metadata shape so the template knows which view to render.

    * `:diff`  — has both `before` + `after` keys (the
                 `application.update` shape we land in the audit since
                 the v3.0.2 hardening PR).
    * `:flat`  — any other map; render as plain pretty JSON.
    * `:none`  — empty / nil.
  """
  def metadata_shape(%{"before" => _, "after" => _}), do: :diff
  def metadata_shape(m) when is_map(m) and map_size(m) > 0, do: :flat
  def metadata_shape(_), do: :none

  @doc """
  Side-by-side diff rows for the `:diff` case. Each entry is
  `{key, before_value, after_value, changed?}` where `changed?` is
  the strict-equality test on the two values (lists of maps compare
  by structure, which is what we want for `l7_rules`).
  """
  def metadata_diff_rows(%{"before" => b, "after" => a}) do
    keys =
      MapSet.union(
        MapSet.new(Map.keys(b || %{})),
        MapSet.new(Map.keys(a || %{}))
      )
      |> MapSet.to_list()
      |> Enum.sort()

    Enum.map(keys, fn key ->
      bv = Map.get(b || %{}, key)
      av = Map.get(a || %{}, key)
      {key, bv, av, bv != av}
    end)
  end

  def metadata_diff_rows(_), do: []

  @doc """
  Pretty-print one cell value. Scalars render inline; lists / maps
  pretty-JSON over multiple lines. The empty / nil case shows `—`
  so a missing key reads as "not set" instead of literal "null".
  """
  def pretty_value(nil),     do: "—"
  def pretty_value(""),      do: "—"
  def pretty_value(v) when is_binary(v),  do: v
  def pretty_value(v) when is_number(v),  do: to_string(v)
  def pretty_value(true),    do: "true"
  def pretty_value(false),   do: "false"

  def pretty_value(v) when is_list(v) or is_map(v) do
    Jason.encode!(v, pretty: true)
  end

  def pretty_value(v), do: inspect(v)

  @doc "Full pretty JSON for the `:flat` metadata case."
  def pretty_json(map) when is_map(map), do: Jason.encode!(map, pretty: true)
  def pretty_json(_), do: ""

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
