defmodule FzHttpWeb.DashboardLive.Index do
  use FzHttpWeb, :live_view

  alias FzHttp.{Users, Devices, Rules}

  @page_title "Dashboard"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    rule_count =
      case Rules.list_rules(socket.assigns.subject) do
        {:ok, rules} -> length(rules)
        _ -> 0
      end

    socket =
      socket
      |> assign(:page_title, @page_title)
      |> assign(:user_count, Users.count())
      |> assign(:device_count, Devices.count())
      |> assign(:active_device_count, Devices.count_active_within(180))
      |> assign(:rule_count, rule_count)

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end
end
