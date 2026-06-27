defmodule FzHttpWeb.SettingLive.L7 do
  @moduledoc """
  Org-level L7 enforcement settings (ADR-014).

  Two operator decisions live here, both audited + both behind a
  confirm modal:
    * `org_settings.l7_enabled` — the kill switch that controls
      whether nftables TPROXY + CoreDNS + L7 proxy are active.
    * `coredns_forward_to[_fallback]` — upstream DNS list CoreDNS
      uses for everything not in the L7 hosts file. Saving these
      rewrites `/etc/nexguard/Corefile.generated` and is effectively
      destructive to in-flight DNS resolution.

  Per-app `enabled` toggles live on each app's Show page; the
  applications surface is the canonical "what's running" view.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{OrgSettings, Applications}

  @page_title "L7 Enforcement"
  @page_subtitle "Org-wide kill switch + CoreDNS forward configuration."

  # Helper visible to the template: render a server list as a comma
  # +space string for the textbox default value.
  def to_csv_str(nil),                  do: ""
  def to_csv_str([]),                   do: ""
  def to_csv_str(l) when is_list(l),    do: Enum.join(l, ", ")
  def to_csv_str(_),                    do: ""

  # Format the "last edited" timestamp for the status hint.
  def updated_at_str(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60    -> "<1m ago"
      diff < 3600  -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true         -> "#{div(diff, 86400)}d ago"
    end
  end

  def updated_at_str(_), do: "—"

  @doc "DNS forwarder count surfaced on the stats strip."
  def dns_count(%{coredns_forward_to: primary, coredns_forward_to_fallback: fallback}) do
    length(primary || []) + length(fallback || [])
  end

  def dns_count(_), do: 0

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, @page_title)
     |> assign(:page_subtitle, @page_subtitle)
     |> assign(:confirm, nil)
     |> assign(:pending_dns, nil)
     |> reload_assigns()}
  end

  defp reload_assigns(socket) do
    settings = OrgSettings.get()

    enabled_apps_count =
      case Applications.list_applications(socket.assigns.subject) do
        {:ok, apps} -> Enum.count(apps, & &1.enabled)
        _ -> 0
      end

    socket
    |> assign(:settings, settings)
    |> assign(:enabled_apps_count, enabled_apps_count)
  end

  # ── Confirm-before-toggle ──────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("request_enable", _, socket),
    do: {:noreply, assign(socket, :confirm, :enable)}

  def handle_event("request_disable", _, socket),
    do: {:noreply, assign(socket, :confirm, :disable)}

  def handle_event("cancel", _, socket),
    do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("apply", _, %{assigns: %{confirm: :enable}} = socket) do
    case OrgSettings.set_l7_enabled(true, socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:confirm, nil)
         |> reload_assigns()
         |> put_flash(:info, "L7 enforcement enabled.")}

      _ ->
        {:noreply,
         socket
         |> assign(:confirm, nil)
         |> put_flash(:error, "Could not enable L7.")}
    end
  end

  def handle_event("apply", _, %{assigns: %{confirm: :disable}} = socket) do
    case OrgSettings.set_l7_enabled(false, socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:confirm, nil)
         |> reload_assigns()
         |> put_flash(:info, "L7 enforcement disabled — kill switch flipped.")}

      _ ->
        {:noreply,
         socket
         |> assign(:confirm, nil)
         |> put_flash(:error, "Could not disable L7.")}
    end
  end

  # ── DNS forward upstreams (confirm before save) ───────────────

  # Form submit → capture the parsed values in :pending_dns and open
  # the confirm modal. Save only fires on explicit confirm because
  # CoreDNS reload interrupts in-flight resolution.
  def handle_event("request_save_dns", %{"dns" => params}, socket) do
    pending = %{
      primary:  split_csv(params["primary"]  || ""),
      fallback: split_csv(params["fallback"] || "")
    }

    {:noreply, assign(socket, :pending_dns, pending)}
  end

  def handle_event("cancel_save_dns", _, socket),
    do: {:noreply, assign(socket, :pending_dns, nil)}

  def handle_event("apply_dns", _, %{assigns: %{pending_dns: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("apply_dns", _, %{assigns: %{pending_dns: pending}} = socket) do
    case OrgSettings.set_dns_forward(pending.primary, pending.fallback,
                                     socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:pending_dns, nil)
         |> reload_assigns()
         |> put_flash(:info, "DNS upstreams updated — CoreDNS picks up within 1s.")}

      {:error, %Ecto.Changeset{} = cs} ->
        msg =
          cs.errors
          |> Enum.map(fn {field, {m, _}} -> "#{field}: #{m}" end)
          |> Enum.join("; ")

        {:noreply,
         socket
         |> assign(:pending_dns, nil)
         |> put_flash(:error, "Invalid: #{msg}")}

      _ ->
        {:noreply,
         socket
         |> assign(:pending_dns, nil)
         |> put_flash(:error, "Could not update DNS forwarders.")}
    end
  end

  defp split_csv(str) when is_binary(str) do
    str
    |> String.split([",", " ", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_csv(_), do: []
end
