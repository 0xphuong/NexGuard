defmodule FzHttpWeb.AuthController do
  @moduledoc """
  Implements the CRUD for a Session
  """
  use FzHttpWeb, :controller
  alias FzHttp.{AuditLogs, Config, NativeAuth, Users}
  alias FzHttp.Auth
  alias FzHttp.Auth.MFA
  alias FzHttpWeb.Auth.HTML.Authentication
  alias FzHttpWeb.OAuth.PKCE
  alias FzHttpWeb.OIDC.State
  alias FzHttpWeb.UserFromAuth
  require Logger

  # Uncomment when Helpers.callback_url/1 is fixed
  # alias Ueberauth.Strategy.Helpers

  plug Ueberauth

  def request(conn, _params) do
    path = ~p"/auth/identity/callback"

    conn
    |> render("request.html", callback_path: path)
  end

  # Ueberauth failed before we even reached the user lookup (bad form input, etc.)
  def callback(%{assigns: %{ueberauth_failure: %{errors: errors}}} = conn, _params) do
    msg = Enum.map_join(errors, ". ", fn error -> error.message end)

    AuditLogs.log("auth.login.failure",
      ip_address: format_remote_ip(conn.remote_ip),
      result: "failure",
      metadata: %{provider: "identity", reason: msg}
    )

    conn
    |> put_flash(:error, msg)
    |> redirect(to: ~p"/")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case UserFromAuth.find_or_create(auth) do
      {:ok, user} ->
        do_sign_in(conn, user, auth)

      {:error, reason} when reason in [:not_found, :invalid_credentials] ->
        AuditLogs.log("auth.login.failure",
          ip_address: format_remote_ip(conn.remote_ip),
          result: "failure",
          metadata: %{
            provider: "identity",
            reason: to_string(reason),
            email: auth.info.email
          }
        )

        conn
        |> put_flash(
          :error,
          "Error signing in: user credentials are invalid or user does not exist"
        )
        |> request(%{})

      {:error, reason} ->
        AuditLogs.log("auth.login.failure",
          ip_address: format_remote_ip(conn.remote_ip),
          result: "failure",
          metadata: %{provider: "identity", reason: to_string(reason)}
        )

        conn
        |> put_flash(:error, "Error signing in: #{reason}")
        |> request(%{})
    end
  end

  # This can be called if the user attempts to visit one of the callback redirect URLs
  # directly.
  def callback(conn, params) do
    conn
    |> put_flash(:error, inspect(params) <> inspect(conn.assigns))
    |> redirect(to: ~p"/")
  end

  def oidc_callback(conn, %{"provider" => provider_id, "state" => state} = params)
      when is_binary(provider_id) do
    token_params = Map.merge(params, PKCE.token_params(conn))

    with :ok <- State.verify_state(conn, state),
         {:ok, config} <- Auth.fetch_oidc_provider_config(provider_id),
         {:ok, tokens} <- OpenIDConnect.fetch_tokens(config, token_params),
         {:ok, claims} <- OpenIDConnect.verify(config, tokens["id_token"]) do
      case UserFromAuth.find_or_create(provider_id, claims) do
        {:ok, user} ->
          # only first-time connect will include refresh token
          # XXX: Remove this when SCIM 2.0 is implemented
          with %{"refresh_token" => refresh_token} <- tokens do
            FzHttp.Auth.OIDC.create_connection(user.id, provider_id, refresh_token)
          end

          conn
          |> put_session("id_token", tokens["id_token"])
          |> do_sign_in(user, %{provider: provider_id})

        {:error, reason} ->
          AuditLogs.log("auth.login.failure",
            ip_address: format_remote_ip(conn.remote_ip),
            result: "failure",
            metadata: %{provider: provider_id, reason: to_string(reason)}
          )

          conn
          |> State.delete_cookie()
          |> PKCE.delete_cookie()
          |> put_flash(:error, "Error signing in: #{reason}")
          |> redirect(to: ~p"/")
      end
    else
      {:error, error} ->
        msg = "An OpenIDConnect error occurred. Details: #{inspect(error)}"
        Logger.error(msg)

        AuditLogs.log("auth.login.failure",
          ip_address: format_remote_ip(conn.remote_ip),
          result: "failure",
          metadata: %{provider: provider_id, reason: msg}
        )

        conn
        |> State.delete_cookie()
        |> PKCE.delete_cookie()
        |> put_flash(:error, msg)
        |> redirect(to: ~p"/")
    end
  end

  def saml_callback(conn, _params) do
    key = {idp, _} = get_session(conn, "samly_assertion_key")
    assertion = %Samly.Assertion{} = Samly.State.get_assertion(conn, key)

    with {:ok, user} <-
           UserFromAuth.find_or_create(:saml, idp, %{"email" => assertion.subject.name}) do
      do_sign_in(conn, user, %{provider: idp})
    else
      {:error, %{errors: [email: {"is invalid email address", _metadata}]}} ->
        AuditLogs.log("auth.login.failure",
          ip_address: format_remote_ip(conn.remote_ip),
          result: "failure",
          metadata: %{provider: idp, reason: "invalid_email_from_saml_assertion"}
        )

        conn
        |> put_flash(
          :error,
          "SAML provider did not return a valid email address in `name` assertion"
        )
        |> redirect(to: ~p"/")

      {:error, reason} when is_binary(reason) ->
        AuditLogs.log("auth.login.failure",
          ip_address: format_remote_ip(conn.remote_ip),
          result: "failure",
          metadata: %{provider: idp, reason: reason}
        )

        conn
        |> put_flash(:error, reason)
        |> redirect(to: ~p"/")

      other ->
        other
    end
  end

  def delete(conn, _params) do
    Authentication.sign_out(conn)
  end

  @doc """
  Finalize the native auth flow AFTER an MFA challenge has been completed via
  the web LiveView. Reads the deferred `:native_flow` session, issues the
  one-time code, drops the temporary browser session, and redirects to the
  client's `nexguard-connect://` scheme.

  Only reachable when the user is browser-authenticated (route is in the
  authenticated scope), which is the case immediately after MFA verify.
  """
  def native_finalize(conn, _params) do
    user = Authentication.get_current_subject(conn) |> current_user_from_subject()

    case {user, get_session(conn, :native_flow)} do
      {nil, _} ->
        conn |> put_flash(:error, "Session expired.") |> redirect(to: ~p"/")

      {_user, nil} ->
        conn |> put_flash(:error, "No native sign-in in progress.") |> redirect(to: ~p"/")

      {%Users.User{} = user,
       %{"state" => state, "code_challenge" => cc, "redirect_uri" => ru}} ->
        complete_native_flow(conn, user, %{provider: :mfa}, state, cc, ru)
    end
  end

  defp current_user_from_subject(%Auth.Subject{actor: {:user, %Users.User{} = user}}), do: user
  defp current_user_from_subject(_), do: nil

  def reset_password(conn, _params) do
    render(conn, "reset_password.html")
  end

  def magic_link(conn, %{"email" => email}) do
    with {:ok, user} <- Users.fetch_user_by_email(email),
         {:ok, user} <- Users.request_sign_in_token(user) do
      FzHttpWeb.Mailer.AuthEmail.magic_link(user)
      |> FzHttpWeb.Mailer.deliver!()

      conn
      |> put_flash(:info, "Please check your inbox for the magic link.")
      |> redirect(to: ~p"/")
    else
      {:error, :not_found} ->
        conn
        |> put_flash(:warning, "Failed to send magic link email.")
        |> redirect(to: ~p"/auth/reset_password")
    end
  end

  def magic_sign_in(conn, %{"user_id" => user_id, "token" => token}) do
    with {:ok, user} <- Users.fetch_user_by_id(user_id),
         {:ok, _user} <- Users.consume_sign_in_token(user, token) do
      do_sign_in(conn, user, %{provider: :magic_link})
    else
      {:error, _reason} ->
        AuditLogs.log("auth.login.failure",
          ip_address: format_remote_ip(conn.remote_ip),
          result: "failure",
          metadata: %{provider: "magic_link", reason: "invalid_or_expired_token"}
        )

        conn
        |> put_flash(:error, "The magic link is not valid or has expired.")
        |> redirect(to: ~p"/")
    end
  end

  def redirect_oidc_auth_uri(conn, %{"provider" => provider_id}) when is_binary(provider_id) do
    verifier = PKCE.code_verifier()

    params = %{
      access_type: :offline,
      state: State.new(),
      code_challenge_method: PKCE.code_challenge_method(),
      code_challenge: PKCE.code_challenge(verifier)
    }

    with {:ok, config} <- Auth.fetch_oidc_provider_config(provider_id),
         {:ok, uri} <- OpenIDConnect.authorization_uri(config, params) do
      conn
      |> PKCE.put_cookie(verifier)
      |> State.put_cookie(params.state)
      |> redirect(external: uri)
    else
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Cannot redirect user to OIDC auth uri", reason: inspect(reason))

        conn
        |> put_flash(:error, "Error while processing OpenID request.")
        |> redirect(to: ~p"/")
    end
  end

  defp do_sign_in(conn, user, auth) do
    case get_session(conn, :native_flow) do
      %{"state" => st, "code_challenge" => cc, "redirect_uri" => ru} ->
        if MFA.has_methods?(user) do
          # MFA required — sign user into the browser session (Guardian) so the
          # MFA LiveView can authenticate them, then redirect to the MFA challenge.
          # `:native_flow` stays in the session; MFA LiveView reads it on success
          # and redirects to /auth/native/finalize which completes the native
          # flow (creates the code, drops the browser session, redirects to scheme).
          conn
          |> State.delete_cookie()
          |> PKCE.delete_cookie()
          |> Authentication.sign_in(user, auth)
          |> configure_session(renew: true)
          |> redirect(to: mfa_entry_path(user))
        else
          complete_native_flow(conn, user, auth, st, cc, ru)
        end

      _ ->
        conn
        |> State.delete_cookie()
        |> PKCE.delete_cookie()
        |> Authentication.sign_in(user, auth)
        |> configure_session(renew: true)
        |> put_session(:live_socket_id, "users_socket:#{user.id}")
        |> redirect(to: root_path_for_user(user))
    end
  end

  defp mfa_entry_path(user) do
    case MFA.fetch_last_used_method_by_user_id(user.id) do
      {:ok, method} -> ~p"/mfa/auth/#{method.id}"
      _ -> ~p"/mfa/types"
    end
  end

  defp auth_provider_label(%{provider: p}) when not is_nil(p), do: to_string(p)
  defp auth_provider_label(_), do: "unknown"

  defp complete_native_flow(conn, user, auth, state, code_challenge, redirect_uri) do
    provider_label = auth_provider_label(auth)

    case NativeAuth.create_code(user, code_challenge, redirect_uri) do
      {:ok, code} ->
        # Mirror the side-effects of Authentication.sign_in/3 so portal "last sign in"
        # and audit query for "auth.login.success" cover native sign-ins too.
        unless Config.fetch_config!(:require_mfa) do
          Users.update_last_signed_in(user, auth)
        end

        AuditLogs.log("auth.login.success",
          actor_id: user.id,
          actor_email: user.email,
          ip_address: format_remote_ip(conn.remote_ip),
          metadata: %{provider: provider_label, native: true}
        )

        AuditLogs.log("auth.native.code_issued",
          ip_address: format_remote_ip(conn.remote_ip),
          result: "success",
          metadata: %{provider: provider_label, user_id: user.id}
        )

        target =
          redirect_uri <>
            "?code=" <>
            URI.encode_www_form(code) <>
            "&state=" <> URI.encode_www_form(state)

        conn
        |> delete_session(:native_flow)
        |> State.delete_cookie()
        |> PKCE.delete_cookie()
        |> configure_session(drop: true)
        |> redirect(external: target)

      {:error, reason} ->
        Logger.error("native_auth code creation failed", reason: inspect(reason))

        AuditLogs.log("auth.native.code_issued",
          ip_address: format_remote_ip(conn.remote_ip),
          result: "failure",
          metadata: %{provider: provider_label, reason: inspect(reason)}
        )

        conn
        |> delete_session(:native_flow)
        |> State.delete_cookie()
        |> PKCE.delete_cookie()
        |> put_flash(:error, "Could not complete native sign-in: #{inspect(reason)}")
        |> redirect(to: ~p"/")
    end
  end
end
