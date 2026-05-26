defmodule FzHttpWeb.SettingLive.ShowApiTokenComponent do
  use FzHttpWeb, :live_component

  alias Phoenix.LiveView.JS
  alias FzHttpWeb.Auth.JSON.Authentication

  def update(assigns, socket) do
    if connected?(socket) do
      {:ok, secret, _claims} = Authentication.fz_encode_and_sign(assigns.api_token)

      {:ok,
       socket
       |> assign(:secret, secret)}
    else
      {:ok, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <%= if assigns[:secret] do %>
        <div style="display:flex;align-items:center;justify-content:space-between;gap:0.75rem;margin-bottom:0.5rem">
          <span class="ng-label" style="margin-bottom:0">API token secret</span>
          <button
            class="ng-secondary-btn copy-button"
            phx-click={JS.dispatch("nexguard:clipcopy", to: "#api-token-secret")}
            title="Click to copy API token"
          >
            <i class="mdi mdi-content-copy"></i> Copy
          </button>
        </div>
        <pre class="multiline" style="margin-bottom:0.75rem"><code id="api-token-secret"><%= @secret %></code></pre>
        <div class="ng-flash ng-flash--info" style="margin-bottom:1rem">
          <i class="mdi mdi-alert-circle-outline ng-flash-icon"></i>
          <span class="ng-flash-message"><strong>Warning!</strong> This token is sensitive. Store it somewhere safe.</span>
        </div>
        <hr />
        <p class="ng-label" style="margin-bottom:0.5rem">cURL example</p>
        <pre><code id="api-usage-example"><i># List all users</i>
curl -H 'Content-Type: application/json' \
     -H 'Authorization: Bearer <%= @secret %>' \
     <%= FzHttp.Config.fetch_env!(:fz_http, :external_url) %>/v0/users</code></pre>
        <div style="text-align:right;margin-top:0.75rem">
          <a class="ng-inline-link" href="https://docs.nexguard.binhphuong.io.vn/reference/rest-api?utm_source=product">
            Explore the REST API docs <i class="mdi mdi-arrow-right"></i>
          </a>
        </div>
      <% end %>
    </div>
    """
  end
end
