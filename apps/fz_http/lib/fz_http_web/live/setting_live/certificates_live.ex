defmodule FzHttpWeb.SettingLive.Certificates do
  @moduledoc """
  Admin-facing TLS certificate library (ADR-015).

  Lists every cert in the shared library, surfaces coverage / issuer /
  expiry / usage count, and gates the upload / replace / delete
  actions through `FzHttp.L7.TlsCertificates`.

  Three live_actions on the same module:
    * `:show`    — bare list (default)
    * `:new`     — list + upload modal (`/settings/certificates/new`)
    * `:replace` — list + replace modal for a specific cert id
                   (`/settings/certificates/:id/replace`)

  Delete is a confirm-modal flow rendered inline (no route param) —
  same shape as `ApplicationsLive.Index.delete_confirm`.

  Filter bar narrows the list by label/SAN substring or by expiry
  bucket (healthy / warning / critical / expired). Stats strip
  always reflects the WHOLE library so the org-wide pulse stays
  accurate regardless of filter.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.L7.TlsCertificates

  @page_title "TLS Certificates"
  @page_subtitle "Shared certificates that L7 applications reference by hostname coverage."

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    with {:ok, certs} <- TlsCertificates.list_certificates(socket.assigns.subject) do
      hydrated = hydrate_usage(certs)
      filters = default_filters()

      {:ok,
       socket
       |> assign(:all_certificates, hydrated)
       |> assign(:certificates, apply_filters(hydrated, filters))
       |> assign(:stats, compute_stats(hydrated))
       |> assign(:filters, filters)
       |> assign(:expiry_options, expiry_options())
       |> assign(:delete_confirm, nil)
       |> assign(:replace_target, nil)
       |> assign(:page_title, @page_title)
       |> assign(:page_subtitle, @page_subtitle)}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params),
    do: assign(socket, :replace_target, nil)

  defp apply_action(socket, :new, _params),
    do: assign(socket, :replace_target, nil)

  defp apply_action(socket, :replace, %{"id" => id}) do
    case TlsCertificates.fetch_certificate_by_id(id, socket.assigns.subject) do
      {:ok, cert} ->
        assign(socket, :replace_target, cert)

      {:error, _} ->
        socket
        |> put_flash(:error, "Certificate not found.")
        |> push_navigate(to: ~p"/settings/certificates")
    end
  end

  # ── Filters ─────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = Map.merge(socket.assigns.filters, params)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:certificates, apply_filters(socket.assigns.all_certificates, filters))}
  end

  def handle_event("reset_filters", _params, socket) do
    filters = default_filters()

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:certificates, apply_filters(socket.assigns.all_certificates, filters))}
  end

  # ── Delete confirm modal ────────────────────────────────────────

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    case TlsCertificates.fetch_certificate_by_id(id, socket.assigns.subject) do
      {:ok, cert} ->
        affected = TlsCertificates.affected_apps(cert)

        {:noreply,
         assign(socket, :delete_confirm, %{cert: cert, affected: affected})}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Certificate not found.")}
    end
  end

  def handle_event("cancel_delete", _, socket),
    do: {:noreply, assign(socket, :delete_confirm, nil)}

  def handle_event("delete", _, %{assigns: %{delete_confirm: %{cert: cert}}} = socket) do
    case TlsCertificates.delete_certificate(cert, socket.assigns.subject,
                                             socket.assigns[:remote_ip]) do
      {:ok, _} ->
        {:ok, certs} = TlsCertificates.list_certificates(socket.assigns.subject)
        hydrated = hydrate_usage(certs)

        {:noreply,
         socket
         |> assign(:all_certificates, hydrated)
         |> assign(:certificates, apply_filters(hydrated, socket.assigns.filters))
         |> assign(:stats, compute_stats(hydrated))
         |> assign(:delete_confirm, nil)
         |> put_flash(:info, "Certificate \"#{cert.label}\" deleted.")}

      {:error, {:pinned_apps_exist, hostnames}} ->
        joined = Enum.join(hostnames, ", ")

        {:noreply,
         socket
         |> assign(:delete_confirm, nil)
         |> put_flash(:error,
              "Can't delete — still pinned by: #{joined}. Reassign those apps first.")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:delete_confirm, nil)
         |> put_flash(:error, "Could not delete certificate.")}
    end
  end

  # Refresh assigns when the form_component finishes a save
  # (it `send/2`s to the live_view).
  @impl Phoenix.LiveView
  def handle_info({:certificates_refresh, flash}, socket) do
    {:ok, certs} = TlsCertificates.list_certificates(socket.assigns.subject)
    hydrated = hydrate_usage(certs)

    {:noreply,
     socket
     |> assign(:all_certificates, hydrated)
     |> assign(:certificates, apply_filters(hydrated, socket.assigns.filters))
     |> assign(:stats, compute_stats(hydrated))
     |> put_flash(flash.kind, flash.message)}
  end

  # ── Helpers for template ────────────────────────────────────────

  @doc false
  def expiry_status(%DateTime{} = not_after) do
    days = DateTime.diff(not_after, DateTime.utc_now(), :day)

    cond do
      days <= 0  -> {:expired,   "Expired"}
      days <= 7  -> {:critical,  "#{days}d left"}
      days <= 30 -> {:warning,   "#{days}d left"}
      true       -> {:healthy,   "#{days}d left"}
    end
  end

  def expiry_status(_), do: {:unknown, "—"}

  @doc false
  def format_datetime(%DateTime{} = dt) do
    "#{dt.year}-#{pad(dt.month)}-#{pad(dt.day)}"
  end

  def format_datetime(_), do: "—"

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n),             do: "#{n}"

  @doc """
  Modifier for the dedicated `.ng-cert-status-badge` class. Earlier
  versions returned source-badge variants (`"manual"` / `"idp_sync"`)
  which collided with the provenance palette used by access-groups
  and members. Now an axis of its own.
  """
  def status_badge_class(:expired),  do: "expired"
  def status_badge_class(:critical), do: "critical"
  def status_badge_class(:warning),  do: "warning"
  def status_badge_class(:healthy),  do: "healthy"
  def status_badge_class(_),         do: "unknown"

  @doc false
  def status_icon(:expired),  do: "mdi-alert-octagon"
  def status_icon(:critical), do: "mdi-alert"
  def status_icon(:warning),  do: "mdi-clock-alert-outline"
  def status_icon(:healthy),  do: "mdi-check-circle-outline"
  def status_icon(_),         do: "mdi-help-circle-outline"

  def filters_active?(%{"search" => s, "expiry" => e}) do
    s != "" or e != "all"
  end

  # ── Internal ────────────────────────────────────────────────────

  defp default_filters do
    %{"search" => "", "expiry" => "all"}
  end

  defp expiry_options do
    [
      {"Expiry: All",  "all"},
      {"Healthy",      "healthy"},
      {"Expiring",     "warning"},
      {"Critical",     "critical"},
      {"Expired",      "expired"}
    ]
  end

  defp apply_filters(certs, %{"search" => search, "expiry" => expiry}) do
    certs
    |> Enum.filter(&match_search?(&1, search))
    |> Enum.filter(&match_expiry?(&1, expiry))
  end

  defp match_search?(_cert, ""), do: true

  defp match_search?(cert, query) do
    q = String.downcase(query)
    label = String.downcase(cert.label || "")
    primary = String.downcase(cert.primary_san || "")

    in_label = String.contains?(label, q)
    in_primary = String.contains?(primary, q)

    in_sans =
      cert.sans
      |> List.wrap()
      |> Enum.any?(fn s -> String.contains?(String.downcase(s || ""), q) end)

    in_label or in_primary or in_sans
  end

  defp match_expiry?(_cert, "all"), do: true

  defp match_expiry?(cert, expiry) do
    {status, _} = expiry_status(cert.not_after)
    Atom.to_string(status) == expiry
  end

  defp compute_stats(certs) do
    by_status =
      Enum.frequencies_by(certs, fn c ->
        {status, _} = expiry_status(c.not_after)
        status
      end)

    %{
      total:     length(certs),
      expired:   Map.get(by_status, :expired, 0),
      critical:  Map.get(by_status, :critical, 0),
      warning:   Map.get(by_status, :warning, 0),
      apps:      Enum.sum(Enum.map(certs, &(&1.pinned_count + &1.auto_matched_count)))
    }
  end

  # Decorate each cert with usage counts so the table can render
  # "Used by N apps" without N+1 round trips.
  defp hydrate_usage(certs) do
    Enum.map(certs, fn cert ->
      affected = TlsCertificates.affected_apps(cert)

      Map.merge(cert, %{
        pinned_count: length(affected.pinned),
        auto_matched_count: length(affected.auto_matched),
        pinned_hostnames: Enum.map(affected.pinned, & &1.hostname),
        auto_matched_hostnames: Enum.map(affected.auto_matched, & &1.hostname)
      })
    end)
  end
end
