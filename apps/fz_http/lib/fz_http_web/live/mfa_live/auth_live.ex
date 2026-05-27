defmodule FzHttpWeb.MFALive.Auth do
  @moduledoc """
  Handles MFA LiveViews.
  """
  use FzHttpWeb, :live_view
  import FzHttpWeb.ControllerHelpers
  alias FzHttp.Auth.MFA
  alias FzHttp.{Users, Config}

  @page_title "Multi-factor Authentication"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, @page_title)}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, %{assigns: %{live_action: :types}} = socket) do
    {:ok, methods} = MFA.list_methods_for_user(socket.assigns.current_user)
    socket = assign(socket, :methods, methods)
    {:noreply, socket}
  end

  def handle_params(%{"id" => id}, _uri, socket) do
    with {:ok, method} <- MFA.fetch_method_by_id(id),
         true <- method.user_id == socket.assigns.current_user.id do
      changeset = MFA.use_method_changeset(method)

      socket =
        socket
        |> assign(:changeset, changeset)
        |> assign(:method, method)

      {:noreply, socket}
    else
      _ -> {:halt, redirect(socket, to: ~p"/")}
    end
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :auth} = assigns) do
    ~H"""
    <div class="auth-card">
      <div class="auth-card-header">
        <div class="auth-icon-badge">
          <span class="mdi mdi-cellphone-key"></span>
        </div>
        <h1 class="auth-title">Two-Factor Authentication</h1>
        <p class="auth-subtitle">Enter the 6-digit code from your authenticator app</p>
      </div>
      <div class="auth-card-body">
        <.link navigate={~p"/mfa/types"} class="auth-back-link">
          <span class="mdi mdi-arrow-left"></span> Use a different authenticator
        </.link>

        <.form :let={f} for={@changeset} id="mfa-method-form" phx-submit="verify" class="auth-form">
          <div class="auth-field">
            <label class="auth-label">Authentication Code</label>
            <div class="auth-input-wrap">
              <span class="mdi mdi-numeric auth-input-icon"></span>
              <%= text_input(f, :code,
                name: "code",
                placeholder: "000000",
                required: true,
                autocomplete: "one-time-code",
                inputmode: "numeric",
                class: "auth-input #{input_error_class(@changeset, :code)}",
                style: "letter-spacing:0.3em;font-family:'Fira Mono',monospace;font-size:1.25rem;text-align:center;padding-left:2.5rem"
              ) %>
            </div>
            <p style="color:#ef4444;font-size:0.8125rem;min-height:1.1em">
              <%= error_tag(f, :code) %>
            </p>
          </div>

          <div class="auth-form-actions">
            <%= submit("Verify Code",
              phx_disable_with: "Verifying…",
              class: "auth-submit-btn"
            ) %>
            <%= link to: ~p"/sign_out", method: :delete, class: "auth-link" do %>
              Sign out
            <% end %>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :types} = assigns) do
    ~H"""
    <div class="auth-card">
      <div class="auth-card-header">
        <div class="auth-icon-badge">
          <span class="mdi mdi-shield-check-outline"></span>
        </div>
        <h1 class="auth-title">Choose Authenticator</h1>
        <p class="auth-subtitle">Select an MFA method to continue</p>
      </div>
      <div class="auth-card-body">
        <%= for method <- @methods do %>
          <.link navigate={~p"/mfa/auth/#{method.id}"} class="auth-provider-btn">
            <span class="mdi mdi-cellphone-key auth-provider-icon"></span>
            <span>
              <%= method.name %>
              <span style="color:#94a3b8;font-size:0.8rem;margin-left:0.3rem">
                [<%= method.type %>]
              </span>
            </span>
            <span class="mdi mdi-chevron-right auth-provider-arrow"></span>
          </.link>
        <% end %>
      </div>
    </div>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("verify", attrs, socket) do
    case MFA.use_method(socket.assigns.method, attrs) do
      {:ok, _method} ->
        if Config.fetch_config!(:require_mfa) do
          Users.update_last_signed_in(socket.assigns.current_user, %{provider: :mfa})
        end

        socket = push_redirect(socket, to: root_path_for_user(socket.assigns.current_user))
        {:noreply, socket}

      {:error, changeset} ->
        socket = assign(socket, :changeset, changeset)
        {:noreply, socket}
    end
  end
end
