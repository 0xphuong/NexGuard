defmodule FzHttpWeb.RuleLive.Index do
  @moduledoc """
  Handles the L3/L4 egress rules page.

  R-A (v3.0.10): the page was previously a fixed 2-column grid
  rendering Allow + Deny lists side-by-side. At 768–1100px both
  panels ended up cramped — five table columns inside ~480px each
  caused destination/port text to wrap. Allow + Deny are mutually
  exclusive semantics anyway (a rule is one or the other), so the
  view becomes URL-addressable tabs: `/rules` → Allowlist,
  `/rules/deny` → Denylist.
  """
  use FzHttpWeb, :live_view

  @page_title "Egress Rules"
  @page_subtitle "Layer 3/4 egress controls — packets routed through the VPN tunnel are matched against these rules."

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_subtitle, @page_subtitle)
     |> assign(:page_title, @page_title)
     |> assign(:tab, tab_for_action(socket.assigns[:live_action]))}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :tab, tab_for_action(socket.assigns.live_action))}
  end

  defp tab_for_action(:deny), do: :deny
  defp tab_for_action(_),     do: :allow
end
