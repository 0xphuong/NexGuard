defmodule FzHttpWeb.SettingLive.OIDCFormComponent do
  @moduledoc """
  Form for OIDC configs
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
        id="oidc-form"
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
            A unique ID that will be used to generate login URLs for this provider.
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
            Text to display on the Login button.
          </p>
        </div>

        <hr />

        <div class="ng-field">
          <%= label(f, :scope, class: "ng-label") %>
          <%= text_input(f, :scope,
            placeholder: "openid email profile",
            class: "ng-input #{input_error_class(f, :scope)}"
          ) %>
          <p class="ng-field-error">
            <%= error_tag(f, :scope) %>
          </p>
          <p class="ng-field-hint">
            Space-delimited list of OpenID scopes. <code>openid</code>
            and <code>email</code>
            are required in order for NexGuard to work.
          </p>
        </div>

        <hr />

        <div class="ng-field">
          <%= label(f, :response_type, class: "ng-label") %>
          <%= text_input(f, :response_type,
            disabled: true,
            placeholder: "code",
            class: "ng-input #{input_error_class(f, :response_type)}"
          ) %>
          <p class="ng-field-error">
            <%= error_tag(f, :response_type) %>
          </p>
        </div>

        <hr />

        <div class="ng-field">
          <%= label(f, :client_id, "Client ID", class: "ng-label") %>
          <%= text_input(f, :client_id, class: "ng-input #{input_error_class(f, :client_id)}") %>
          <p class="ng-field-error">
            <%= error_tag(f, :client_id) %>
          </p>
        </div>

        <hr />

        <div class="ng-field">
          <%= label(f, :client_secret, class: "ng-label") %>
          <%= text_input(f, :client_secret, class: "ng-input #{input_error_class(f, :client_secret)}") %>
          <p class="ng-field-error">
            <%= error_tag(f, :client_secret) %>
          </p>
        </div>

        <hr />

        <div class="ng-field">
          <%= label(f, :discovery_document_uri, "Discovery Document URI", class: "ng-label") %>
          <%= text_input(f, :discovery_document_uri,
            placeholder: "https://accounts.google.com/.well-known/openid-configuration",
            class: "ng-input #{input_error_class(f, :discovery_document_uri)}"
          ) %>
          <p class="ng-field-error">
            <%= error_tag(f, :discovery_document_uri) %>
          </p>
        </div>

        <hr />

        <div class="ng-field">
          <%= label(f, :redirect_uri, "Redirect URI", class: "ng-label") %>
          <%= text_input(f, :redirect_uri,
            placeholder:
              "#{@external_url}auth/oidc/#{input_value(f, :id) || "{CONFIG_ID}"}/callback/",
            class: "ng-input #{input_error_class(f, :redirect_uri)}"
          ) %>
          <p class="ng-field-error">
            <%= error_tag(f, :redirect_uri) %>
          </p>
          <p class="ng-field-hint">
            Optionally override the Redirect URI. Must match the redirect URI set in your IdP.
            In most cases you shouldn't change this. By default
            <code>
              <%= "#{@external_url}auth/oidc/#{input_value(f, :id) || "{CONFIG_ID}"}/callback/" %>
            </code>
            is used.
          </p>
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
      |> FzHttp.Config.Configuration.OpenIDConnectProvider.create_changeset()

    socket =
      socket
      |> assign(assigns)
      |> assign(:external_url, FzHttp.Config.fetch_env!(:fz_http, :external_url))
      |> assign(:changeset, changeset)

    {:ok, socket}
  end

  def handle_event("save", %{"open_id_connect_provider" => params}, socket) do
    changeset = FzHttp.Config.Configuration.OpenIDConnectProvider.create_changeset(params)

    if changeset.valid? do
      attrs = Ecto.Changeset.apply_changes(changeset)

      config = Config.fetch_db_config!()

      openid_connect_providers =
        config.openid_connect_providers
        |> Enum.reject(&(&1.id == socket.assigns.provider.id))
        |> Kernel.++([attrs])
        |> Enum.map(&Map.from_struct/1)

      {:ok, _config} =
        Config.update_config(
          config,
          %{openid_connect_providers: openid_connect_providers},
          socket.assigns.subject,
          socket.assigns[:remote_ip]
        )

      socket =
        socket
        |> put_flash(:info, "Updated successfully.")
        |> redirect(to: socket.assigns.return_to)

      {:noreply, socket}
    else
      socket = assign(socket, :changeset, render_changeset_errors(changeset))
      {:noreply, socket}
    end
  end
end
