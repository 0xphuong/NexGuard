defmodule FzHttpWeb.SettingLive.SAMLFormComponent do
  @moduledoc """
  Form for SAML configs
  """
  use FzHttpWeb, :live_component
  alias FzHttp.Config

  def render(assigns) do
    ~H"""
    <div>
      <.form
        :let={f}
        for={@changeset}
        autocomplete="off"
        id="saml-form"
        phx-target={@myself}
        phx-submit="save"
      >
        <div class="ng-field">
          <%= label(f, :id, "Config ID", class: "ng-label") %>
          <%= text_input(f, :id, class: "ng-input #{input_error_class(f, :id)}") %>
          <p class="ng-field-error">
            <%= error_tag(f, :id) %>
          </p>
          <p class="ng-field-hint">
            ID used for generating auth URLs.
          </p>
        </div>

        <hr />

        <div class="ng-field">
          <%= label(f, :label, class: "ng-label") %>
          <%= text_input(f, :label, class: "ng-input #{input_error_class(f, :label)}") %>
          <p class="ng-field-error">
            <%= error_tag(f, :label) %>
          </p>
          <p class="ng-field-hint">
            Sign in button text.
          </p>
        </div>

        <hr />

        <div class="ng-field">
          <%= label(f, :base_url, "Base URL", class: "ng-label") %>
          <%= text_input(f, :base_url, class: "ng-input #{input_error_class(f, :base_url)}") %>
          <p class="ng-field-error">
            <%= error_tag(f, :base_url) %>
          </p>
          <p class="ng-field-hint">
            Base URL for the ACS URL. in most cases this shouldn't be changed.
          </p>
        </div>

        <hr />

        <div class="ng-field">
          <%= label(f, :metadata, class: "ng-label") %>
          <%= textarea(f, :metadata,
            rows: 8,
            class: "ng-textarea #{input_error_class(f, :metadata)}"
          ) %>
          <p class="ng-field-error">
            <%= error_tag(f, :metadata) %>
          </p>
          <p class="ng-field-hint">
            IdP metadata XML.
          </p>
        </div>

        <hr />

        <div class="ng-toggle-row">
          <div class="ng-toggle-row-desc">
            <strong>Sign requests</strong>
            <p class="ng-field-hint">Sign SAML requests with your SAML private key.</p>
            <p class="ng-field-error">
              <%= error_tag(f, :sign_requests) %>
            </p>
          </div>
          <div class="ng-toggle-row-control">
            <%= label f, :sign_requests, class: "ng-toggle" do %>
              <%= checkbox(f, :sign_requests) %>
              <span class="ng-toggle-track"><span class="ng-toggle-thumb"></span></span>
            <% end %>
          </div>
        </div>

        <hr />

        <div class="ng-toggle-row">
          <div class="ng-toggle-row-desc">
            <strong>Sign metadata</strong>
            <p class="ng-field-hint">Sign SAML metadata with your SAML private key.</p>
            <p class="ng-field-error">
              <%= error_tag(f, :sign_metadata) %>
            </p>
          </div>
          <div class="ng-toggle-row-control">
            <%= label f, :sign_metadata, class: "ng-toggle" do %>
              <%= checkbox(f, :sign_metadata) %>
              <span class="ng-toggle-track"><span class="ng-toggle-thumb"></span></span>
            <% end %>
          </div>
        </div>

        <hr />

        <div class="ng-toggle-row">
          <div class="ng-toggle-row-desc">
            <strong>Require signed assertions</strong>
            <p class="ng-field-hint">Require assertions from your IdP to be signed.</p>
            <p class="ng-field-error">
              <%= error_tag(f, :signed_assertion_in_resp) %>
            </p>
          </div>
          <div class="ng-toggle-row-control">
            <%= label f, :signed_assertion_in_resp, class: "ng-toggle" do %>
              <%= checkbox(f, :signed_assertion_in_resp) %>
              <span class="ng-toggle-track"><span class="ng-toggle-thumb"></span></span>
            <% end %>
          </div>
        </div>

        <hr />

        <div class="ng-toggle-row">
          <div class="ng-toggle-row-desc">
            <strong>Require signed envelopes</strong>
            <p class="ng-field-hint">Require envelopes from your IdP to be signed.</p>
            <p class="ng-field-error">
              <%= error_tag(f, :signed_envelopes_in_resp) %>
            </p>
          </div>
          <div class="ng-toggle-row-control">
            <%= label f, :signed_envelopes_in_resp, class: "ng-toggle" do %>
              <%= checkbox(f, :signed_envelopes_in_resp) %>
              <span class="ng-toggle-track"><span class="ng-toggle-thumb"></span></span>
            <% end %>
          </div>
        </div>

        <hr />

        <div class="ng-toggle-row">
          <div class="ng-toggle-row-desc">
            <strong>Auto-create users</strong>
            <p class="ng-field-hint">
              Automatically provision users when signing in for the first time.
            </p>
            <p class="ng-field-error">
              <%= error_tag(f, :auto_create_users) %>
            </p>
          </div>
          <div class="ng-toggle-row-control">
            <%= label f, :auto_create_users, class: "ng-toggle" do %>
              <%= checkbox(f, :auto_create_users) %>
              <span class="ng-toggle-track"><span class="ng-toggle-thumb"></span></span>
            <% end %>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  def update(assigns, socket) do
    changeset =
      assigns.provider
      |> Map.delete(:__struct__)
      |> FzHttp.Config.Configuration.SAMLIdentityProvider.create_changeset()

    socket =
      socket
      |> assign(assigns)
      |> assign(:changeset, changeset)

    {:ok, socket}
  end

  def handle_event("save", %{"saml_identity_provider" => params}, socket) do
    changeset = FzHttp.Config.Configuration.SAMLIdentityProvider.create_changeset(params)

    if changeset.valid? do
      attrs = Ecto.Changeset.apply_changes(changeset)

      config = Config.fetch_db_config!()

      saml_identity_providers =
        config.saml_identity_providers
        |> Enum.reject(&(&1.id == socket.assigns.provider.id))
        |> Kernel.++([attrs])
        |> Enum.map(&Map.from_struct/1)

      {:ok, _config} =
        Config.update_config(
          config,
          %{saml_identity_providers: saml_identity_providers},
          socket.assigns.subject
        )

      socket =
        socket
        |> put_flash(:info, "Updated successfully.")
        |> redirect(to: socket.assigns.return_to)

      {:noreply, socket}
    else
      socket =
        socket
        |> assign(:changeset, render_changeset_errors(changeset))

      {:noreply, socket}
    end
  end
end
