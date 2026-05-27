defmodule FzHttpWeb.OIDCLive.ConnectionsTableComponent do
  @moduledoc """
  OIDC Connections table
  """
  use FzHttpWeb, :live_component
  alias FzHttp.Auth.OIDC

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign_new(:pending_conn_delete, fn -> nil end)}
  end

  def handle_event("refresh", _payload, socket) do
    DynamicSupervisor.start_child(
      FzHttp.RefresherSupervisor,
      {FzHttp.Auth.OIDC.Refresher, {socket.assigns.user.id, 1000}}
    )

    {:noreply,
     socket
     |> put_flash(:info, "A refresh is underway, please check back in a minute.")
     |> push_redirect(to: ~p"/users/#{socket.assigns.user}")}
  end

  def handle_event("open_conn_delete", %{"id" => id, "provider" => provider}, socket) do
    {:noreply, assign(socket, :pending_conn_delete, %{id: id, provider: provider})}
  end

  def handle_event("cancel_conn_delete", _params, socket) do
    {:noreply, assign(socket, :pending_conn_delete, nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    conn = OIDC.get_connection!(id)
    {:ok, _connection} = OIDC.delete_connection(conn)

    {:noreply,
     socket
     |> assign(:pending_conn_delete, nil)
     |> put_flash(:info, "The #{conn.provider} connection is deleted.")
     |> push_redirect(to: ~p"/users/#{socket.assigns.user}")}
  end
end
