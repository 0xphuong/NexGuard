defmodule FzHttpWeb.ApplicationsLive.Show do
  @moduledoc """
  Detail page for one application. Wave 3b-1 ships the read-only
  detail + edit-via-modal + delete. The required-groups picker
  (Wave 3b-3) and L7 rules editor (Wave 3c) plug into separate cards
  on this page in later waves.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Applications

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    case Applications.fetch_application_by_id(id, socket.assigns.subject) do
      {:ok, app} ->
        {:ok,
         socket
         |> assign(:application, app)
         |> assign(:delete_confirm, false)
         |> assign(:page_title, app.name)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Application not found.")
         |> redirect(to: ~p"/applications")}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("confirm_delete", _, socket),
    do: {:noreply, assign(socket, :delete_confirm, true)}

  def handle_event("cancel_delete", _, socket),
    do: {:noreply, assign(socket, :delete_confirm, false)}

  def handle_event("delete", _, socket) do
    case Applications.delete_application(socket.assigns.application, socket.assigns.subject,
                                          socket.assigns[:remote_ip]) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Application deleted.")
         |> push_redirect(to: ~p"/applications")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:delete_confirm, false)
         |> put_flash(:error, "Could not delete application.")}
    end
  end

  def handle_event("toggle_enabled", _, socket) do
    target = !socket.assigns.application.enabled

    case Applications.set_application_enabled(socket.assigns.application, target,
                                                socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, app} ->
        msg = if app.enabled, do: "Application enabled.", else: "Application disabled."
        {:noreply, socket |> assign(:application, app) |> put_flash(:info, msg)}

      {:error, %Ecto.Changeset{} = cs} ->
        # Most likely "cannot enable without an L7 rule" — surface verbatim.
        msg =
          cs
          |> Ecto.Changeset.traverse_errors(fn {m, _} -> m end)
          |> Map.values()
          |> List.flatten()
          |> Enum.join("; ")

        {:noreply, put_flash(socket, :error, "Could not toggle: #{msg}")}
    end
  end
end
