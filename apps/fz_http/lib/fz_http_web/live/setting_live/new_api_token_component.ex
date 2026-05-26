defmodule FzHttpWeb.SettingLive.NewApiTokenComponent do
  @moduledoc """
  Live component to manage creating API Tokens
  """
  use FzHttpWeb, :live_component

  alias FzHttp.ApiTokens

  def render(assigns) do
    ~H"""
    <div>
      <.form
        :let={f}
        for={@changeset}
        autocomplete="off"
        id="api-token-form"
        phx-target={@myself}
        phx-submit="save"
      >
        <%= if @changeset.action do %>
          <div class="ng-flash ng-flash--error" style="margin-bottom: 1rem;">
            <i class="mdi mdi-alert-circle-outline ng-flash-icon"></i>
            <span class="ng-flash-message"><%= error_tag(f, :base) %></span>
          </div>
        <% end %>
        <div class="ng-field ng-field--horizontal">
          <div class="ng-field-label">
            <%= label(f, :expires_in, class: "ng-label") %>
          </div>
          <div class="ng-field-body">
            <div class="ng-input-group">
              <%= text_input(f, :expires_in, class: "ng-input #{input_error_class(f, :expires_in)}") %>
              <span class="ng-input-suffix">days</span>
            </div>
            <p class="ng-field-error">
              <%= error_tag(f, :expires_in) %>
            </p>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  def handle_event("save", %{"api_token" => attrs}, socket) do
    subject = socket.assigns.subject

    case ApiTokens.create_api_token(attrs, subject) do
      {:ok, api_token} ->
        {:noreply,
         socket
         |> push_patch(to: ~p"/settings/account/api_token/#{api_token}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:changeset, changeset)}
    end
  end
end
