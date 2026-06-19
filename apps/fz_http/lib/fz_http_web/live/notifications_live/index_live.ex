defmodule FzHttpWeb.NotificationsLive.Index do
  @moduledoc """
  Real time notifications live view.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Notifications
  alias Phoenix.PubSub

  require Logger

  @topic "notifications_live"
  @page_title "Notifications"
  @page_subtitle "Persisted notifications will appear below."

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    PubSub.subscribe(FzHttp.PubSub, @topic)
    pid = session["notifications_pid"]

    {:ok,
     socket
     |> assign(:notifications_pid, pid)
     |> assign(:notifications, Notifications.current(pid))
     |> assign(:page_subtitle, @page_subtitle)
     |> assign(:page_title, @page_title)}
  end

  @impl Phoenix.LiveView
  def handle_info({:notifications, notifications}, socket) do
    {:noreply,
     socket
     |> assign(notifications: notifications)}
  end

  @impl Phoenix.LiveView
  def handle_event("clear_notification", %{"index" => index}, socket) do
    Notifications.clear_at(socket.assigns.notifications_pid, String.to_integer(index))
    {:noreply, socket}
  end

  defp icon(:error, assigns) do
    ~H"""
    <span class="ng-notif-icon ng-notif-icon--error">
      <i class="mdi mdi-alert-circle-outline"></i>
    </span>
    """
  end

  defp icon(:warning, assigns) do
    ~H"""
    <span class="ng-notif-icon ng-notif-icon--warning">
      <i class="mdi mdi-alert-outline"></i>
    </span>
    """
  end

  defp icon(:info, assigns) do
    ~H"""
    <span class="ng-notif-icon ng-notif-icon--info">
      <i class="mdi mdi-information-outline"></i>
    </span>
    """
  end
end
