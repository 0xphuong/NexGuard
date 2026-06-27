defmodule FzHttpWeb.ConnectivityCheckLive.Index do
  @moduledoc """
  Diagnostic page — lists the last 20 WAN connectivity checks and
  surfaces the current online/offline state + resolved public IP at
  the top so an admin debugging "is the internet down?" gets an
  answer in the first viewport.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.ConnectivityChecks

  @page_title "WAN Connectivity Checks"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    connectivity_checks =
      ConnectivityChecks.list_connectivity_checks(socket.assigns.subject, limit: 20)

    socket =
      socket
      |> assign(:connectivity_checks, connectivity_checks)
      |> assign(:page_title, @page_title)

    {:ok, socket}
  end
end
