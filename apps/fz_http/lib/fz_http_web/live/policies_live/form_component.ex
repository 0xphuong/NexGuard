defmodule FzHttpWeb.PoliciesLive.FormComponent do
  @moduledoc """
  Create a new policy via modal. Edit lives on the Show page
  (inline-edit name + description + default_action), so this
  component handles only the `:new` action.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Policies

  @impl Phoenix.LiveComponent
  def update(%{action: :new} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, Policies.new_policy(%{}))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate", %{"policy" => attrs}, socket) do
    cs =
      attrs
      |> Policies.new_policy()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, cs)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"policy" => attrs}, socket) do
    case Policies.create_policy(attrs, socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, policy} ->
        {:noreply,
         socket
         |> put_flash(:info, "Policy \"#{policy.name}\" created.")
         |> push_redirect(to: ~p"/policies/#{policy}")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :changeset, cs)}
    end
  end
end
