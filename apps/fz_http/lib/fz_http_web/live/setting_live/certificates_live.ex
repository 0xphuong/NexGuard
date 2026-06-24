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
  """
  use FzHttpWeb, :live_view

  alias FzHttp.L7.TlsCertificates

  @page_title "TLS Certificates"
  @page_subtitle "Shared certificates that L7 applications reference by hostname coverage."

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    with {:ok, certs} <- TlsCertificates.list_certificates(socket.assigns.subject) do
      {:ok,
       socket
       |> assign(:certificates, hydrate_usage(certs))
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

  # ── Delete confirm modal ────────────────────────────────────────

  @impl Phoenix.LiveView
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

        {:noreply,
         socket
         |> assign(:certificates, hydrate_usage(certs))
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

    {:noreply,
     socket
     |> assign(:certificates, hydrate_usage(certs))
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

  @doc false
  def status_badge_class(:expired),  do: "manual"
  def status_badge_class(:critical), do: "manual"
  def status_badge_class(:warning),  do: "manual"
  def status_badge_class(:healthy),  do: "idp_sync"
  def status_badge_class(_),         do: "manual"

  @doc false
  def status_icon(:expired),  do: "mdi-alert-octagon"
  def status_icon(:critical), do: "mdi-alert"
  def status_icon(:warning),  do: "mdi-clock-alert-outline"
  def status_icon(:healthy),  do: "mdi-check-circle-outline"
  def status_icon(_),         do: "mdi-help-circle-outline"

  @doc false
  def usage_tooltip(cert) do
    pinned = cert.pinned_hostnames
    auto   = cert.auto_matched_hostnames

    [
      if(pinned != [], do: "Pinned: #{Enum.join(pinned, ", ")}", else: nil),
      if(auto != [],   do: "Auto-matched: #{Enum.join(auto, ", ")}", else: nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" — ")
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
