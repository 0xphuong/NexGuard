defmodule FzHttpWeb.Router do
  @moduledoc """
  Main Application Router
  """

  use FzHttpWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug FzHttpWeb.Plug.CookieHygiene
    plug :fetch_live_flash
    plug :put_root_layout, {FzHttpWeb.LayoutView, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug FzHttpWeb.Auth.JSON.Pipeline
    plug FzHttpWeb.Plug.RequireMFA
  end

  # Unauthenticated JSON pipeline for native client token + refresh endpoints.
  # Trust is established by the request body (one-time code or refresh_token hash).
  pipeline :api_public do
    plug :accepts, ["json"]
  end

  # Native bearer-auth pipeline for authenticated native client endpoints.
  pipeline :api_native_auth do
    plug :accepts, ["json"]
    plug FzHttpWeb.Plug.NativeAuthBearer
  end

  # L7 proxy ↔ NexGuard pipeline. Phase 1 mounts routes here unauthenticated;
  # Phase 6 (B-27) inserts FzHttpWeb.Plugs.MtlsInternal to require a valid
  # internal-CA client cert without any route change.
  pipeline :api_internal do
    plug :accepts, ["json"]
  end

  pipeline :browser_static do
    plug :accepts, ["html", "xml"]
  end

  pipeline :require_authenticated do
    plug Guardian.Plug.EnsureAuthenticated
  end

  pipeline :require_unauthenticated do
    plug Guardian.Plug.EnsureNotAuthenticated
  end

  pipeline :html_auth do
    plug FzHttpWeb.Auth.HTML.Pipeline
  end

  pipeline :require_local_auth do
    plug FzHttpWeb.Plug.RequireLocalAuthentication
  end

  pipeline :samly do
    plug :fetch_session
    plug FzHttpWeb.Plug.SamlyTargetUrl
  end

  # Local auth routes
  scope "/auth", FzHttpWeb do
    pipe_through [
      :browser,
      :html_auth,
      :require_unauthenticated,
      :require_local_auth
    ]

    get "/reset_password", AuthController, :reset_password
    post "/magic_link", AuthController, :magic_link
    get "/magic/:user_id/:token", AuthController, :magic_sign_in

    get "/identity", AuthController, :request
    get "/identity/callback", AuthController, :callback
    post "/identity/callback", AuthController, :callback
  end

  # OIDC auth routes
  scope "/auth", FzHttpWeb do
    scope "/oidc" do
      pipe_through [
        :browser,
        :require_unauthenticated
      ]

      get "/", AuthController, :request
      get "/:provider/callback", AuthController, :oidc_callback
      get "/:provider", AuthController, :redirect_oidc_auth_uri
    end
  end

  # Native client browser bridge — stores PKCE state then delegates to OIDC
  scope "/auth/native", FzHttpWeb do
    pipe_through [
      :browser,
      :require_unauthenticated
    ]

    get "/begin", NativeAuthController, :begin
  end

  # SAML auth routes
  scope "/auth/saml", FzHttpWeb do
    pipe_through [
      :browser,
      :require_unauthenticated
    ]

    get "/", AuthController, :request
    get "/callback", AuthController, :saml_callback
  end

  scope "/auth/saml" do
    pipe_through [
      :samly,
      :require_unauthenticated
    ]

    forward "/", Samly.Router
  end

  # Unauthenticated routes
  scope "/", FzHttpWeb do
    pipe_through [
      :browser,
      :html_auth,
      :require_unauthenticated
    ]

    get "/", RootController, :index
  end

  scope "/mfa", FzHttpWeb do
    pipe_through([
      :browser,
      :html_auth
    ])

    live_session(
      :authenticated,
      on_mount: [
        FzHttpWeb.Hooks.AllowEctoSandbox,
        {FzHttpWeb.LiveAuth, :any},
        {FzHttpWeb.LiveNav, nil}
      ],
      root_layout: {FzHttpWeb.LayoutView, :root}
    ) do
      live "/auth", MFALive.Auth, :auth
      live "/auth/:id", MFALive.Auth, :auth
      live "/types", MFALive.Auth, :types
    end
  end

  # Authenticated routes
  scope "/", FzHttpWeb do
    pipe_through [
      :browser,
      :html_auth,
      :require_authenticated
    ]

    delete "/sign_out", AuthController, :delete
    delete "/user", UserController, :delete

    # Native flow finalize — called after MFA challenge completes for native
    # clients. Creates the one-time auth code + drops session + redirects to
    # nexguard-connect:// scheme. Requires browser authentication.
    get "/auth/native/finalize", AuthController, :native_finalize

    # Unprivileged Live routes
    live_session(
      :unprivileged,
      on_mount: [
        FzHttpWeb.Hooks.AllowEctoSandbox,
        {FzHttpWeb.LiveAuth, :unprivileged},
        {FzHttpWeb.LiveNav, nil},
        FzHttpWeb.LiveMFA
      ],
      root_layout: {FzHttpWeb.LayoutView, :unprivileged}
    ) do
      live "/user_devices", DeviceLive.Unprivileged.Index, :index
      live "/user_devices/new", DeviceLive.Unprivileged.Index, :new
      live "/user_devices/:id", DeviceLive.Unprivileged.Show, :show

      live "/user_account", SettingLive.Unprivileged.Account, :show
      live "/user_account/change_password", SettingLive.Unprivileged.Account, :change_password
      live "/user_account/register_mfa", SettingLive.Unprivileged.Account, :register_mfa
    end

    # Admin Live routes
    live_session(
      :admin,
      on_mount: [
        FzHttpWeb.Hooks.AllowEctoSandbox,
        {FzHttpWeb.LiveAuth, :admin},
        FzHttpWeb.LiveNav,
        FzHttpWeb.LiveMFA
      ],
      root_layout: {FzHttpWeb.LayoutView, :admin}
    ) do
      live "/dashboard", DashboardLive.Index, :index
      live "/users", UserLive.Index, :index
      live "/users/new", UserLive.Index, :new
      live "/users/:id", UserLive.Show, :show
      live "/users/:id/edit", UserLive.Show, :edit
      live "/users/:id/new_device", UserLive.Show, :new_device
      live "/rules", RuleLive.Index, :index
      live "/devices", DeviceLive.Admin.Index, :index
      live "/devices/:id", DeviceLive.Admin.Show, :show

      # L7 ZTNA (ADR-007 → ADR-014)
      live "/access-groups", AccessGroupsLive.Index, :index
      live "/access-groups/new", AccessGroupsLive.Index, :new
      live "/access-groups/:id", AccessGroupsLive.Show, :show

      live "/applications", ApplicationsLive.Index, :index
      live "/applications/new", ApplicationsLive.Index, :new
      live "/applications/:id", ApplicationsLive.Show, :show
      live "/applications/:id/edit", ApplicationsLive.Show, :edit
      live "/settings/client_defaults", SettingLive.ClientDefaults, :show
      live "/settings/network", SettingLive.Network, :show

      live "/settings/security", SettingLive.Security, :show
      live "/settings/security/oidc/:id/edit", SettingLive.Security, :edit_oidc
      live "/settings/security/saml/:id/edit", SettingLive.Security, :edit_saml

      live "/settings/account", SettingLive.Account, :show
      live "/settings/account/edit", SettingLive.Account, :edit
      live "/settings/account/register_mfa", SettingLive.Account, :register_mfa
      live "/settings/account/api_token", SettingLive.Account, :new_api_token
      live "/settings/account/api_token/:api_token_id", SettingLive.Account, :show_api_token
      live "/settings/customization", SettingLive.Customization, :show
      live "/settings/audit_log", SettingLive.AuditLog, :show
      live "/settings/l7", SettingLive.L7, :show
      live "/diagnostics/connectivity_checks", ConnectivityCheckLive.Index, :index
      live "/notifications", NotificationsLive.Index, :index
    end
  end

  scope "/v0", FzHttpWeb.JSON do
    pipe_through :api

    resources "/configuration", ConfigurationController, singleton: true, only: [:show, :update]
    resources "/users", UserController, except: [:new, :edit]
    resources "/devices", DeviceController, except: [:new, :edit]
    resources "/rules", RuleController, except: [:new, :edit]
  end

  # Native client token + refresh (unauthenticated; trust via code/refresh_token in body)
  scope "/api/v1/native", FzHttpWeb.API.V1 do
    pipe_through :api_public

    post "/token", NativeAuthController, :token
    post "/refresh", NativeAuthController, :refresh
    post "/revoke", NativeAuthController, :revoke
  end

  # Native client device endpoints (Bearer-authenticated)
  scope "/api/v1/devices", FzHttpWeb.API.V1 do
    pipe_through :api_native_auth

    post "/enroll", DeviceController, :enroll
    get "/me/config", DeviceController, :me_config
  end

  scope "/browser", FzHttpWeb do
    pipe_through :browser_static

    get "/config.xml", BrowserController, :config
  end

  # L7 ZTNA — public JWKS for proxy/verifier consumption (ADR-010, RFC 8615).
  # Intentionally unauthenticated: public keys are not secrets, and Envoy must
  # fetch them before any TLS handshake against `/internal/*`.
  scope "/.well-known", FzHttpWeb do
    pipe_through :api_public

    get "/jwks.json", WellKnownController, :jwks
  end

  # L7 ZTNA — internal proxy ↔ NexGuard control endpoints (ADR-010).
  # Phase 1 unauthenticated; Phase 6 swaps :api_internal to require mTLS.
  scope "/internal", FzHttpWeb.Internal do
    pipe_through :api_internal

    get "/sessions/by_vpn_ip/:ip", IdentityController, :show
  end

  if Mix.env() in [:dev, :test] do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:browser]

      forward "/mailbox", Plug.Swoosh.MailboxPreview
      live_dashboard "/dashboard"

      get "/samly", FzHttpWeb.DebugController, :samly
      get "/session", FzHttpWeb.DebugController, :session
    end
  end
end
