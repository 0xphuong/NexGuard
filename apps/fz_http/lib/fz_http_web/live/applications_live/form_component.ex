defmodule FzHttpWeb.ApplicationsLive.FormComponent do
  @moduledoc """
  Create / edit a managed application. Wave 3b-1: covers name +
  hostname + backend + cert_source picker (step_ca path only).
  Upload cert path comes in 3b-2; required-groups picker in 3b-3;
  L7 rules row-editor in 3c.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Applications

  @impl Phoenix.LiveComponent
  def update(%{action: :new} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, Applications.change_application())}
  end

  def update(%{action: :edit, application: app} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, Applications.change_application(app))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate", %{"application" => attrs}, %{assigns: %{action: :new}} = socket) do
    cs =
      attrs
      |> Applications.change_new_application()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, cs)}
  end

  def handle_event("validate", %{"application" => attrs}, %{assigns: %{action: :edit}} = socket) do
    cs =
      socket.assigns.application
      |> Applications.change_application(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, cs)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"application" => attrs}, %{assigns: %{action: :new}} = socket) do
    case Applications.create_application(attrs, socket.assigns.subject,
                                          socket.assigns[:remote_ip]) do
      {:ok, app} ->
        {:noreply,
         socket
         |> put_flash(:info, "Application \"#{app.name}\" created.")
         |> push_redirect(to: ~p"/applications/#{app}")}

      {:error, :vip_subnet_exhausted} ->
        {:noreply, put_flash(socket, :error, "Out of virtual IPs in 10.99.0.0/16.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :changeset, cs)}
    end
  end

  def handle_event("save", %{"application" => attrs}, %{assigns: %{action: :edit}} = socket) do
    case Applications.update_application(socket.assigns.application, attrs,
                                          socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, app} ->
        {:noreply,
         socket
         |> put_flash(:info, "Application \"#{app.name}\" updated.")
         |> push_redirect(to: ~p"/applications/#{app}")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :changeset, cs)}
    end
  end
end
