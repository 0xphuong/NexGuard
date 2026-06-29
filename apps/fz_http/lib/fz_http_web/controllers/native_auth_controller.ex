defmodule FzHttpWeb.NativeAuthController do
  @moduledoc """
  Browser bridge for native clients (NexGuard Connect).

  Stores PKCE challenge + custom-scheme redirect URI in the Phoenix session,
  then redirects to the portal sign-in page so the user picks whatever auth method
  the admin has enabled (OIDC, local password, magic link, SAML). After successful
  login, `AuthController.do_sign_in/3` detects the stored `:native_flow` and
  redirects to the custom scheme with a one-time code instead of signing the user
  into the browser portal.

  See `FzHttp.NativeAuth` for the storage layer.
  """
  use FzHttpWeb, :controller
  require Logger

  # Accepted client redirect URIs:
  #   * `nexguard-connect://...`   -- macOS / iOS (custom URL scheme,
  #                                   delivered via ASWebAuthenticationSession).
  #   * `http://127.0.0.1:<port>/..` / `http://localhost:<port>/..` /
  #     `http://[::1]:<port>/..`    -- Windows + Linux desktop, RFC 8252
  #                                   §7.3 loopback redirect.
  # No other http(s) hosts allowed -- pinning to loopback prevents the
  # auth code from being shipped to any remote server.
  @allowed_loopback_hosts ~w(127.0.0.1 localhost ::1)
  @code_challenge_min 43
  @code_challenge_max 128

  def begin(conn, params) do
    state = Map.get(params, "state", "")
    code_challenge = Map.get(params, "code_challenge", "")
    redirect_uri = Map.get(params, "redirect_uri", "")

    with :ok <- validate_state(state),
         :ok <- validate_code_challenge(code_challenge),
         :ok <- validate_redirect_uri(redirect_uri) do
      conn
      |> put_session(:native_flow, %{
        "state" => state,
        "code_challenge" => code_challenge,
        "redirect_uri" => redirect_uri
      })
      |> redirect(to: ~p"/")
    else
      {:error, reason} ->
        Logger.warning("native_auth/begin rejected: #{reason}",
          state: state,
          redirect_uri: redirect_uri
        )

        conn
        |> put_status(:bad_request)
        |> text("invalid native auth request: #{reason}")
    end
  end

  defp validate_state(s) when is_binary(s) and byte_size(s) >= 8 and byte_size(s) <= 256, do: :ok
  defp validate_state(_), do: {:error, "invalid state"}

  defp validate_code_challenge(c)
       when is_binary(c) and byte_size(c) >= @code_challenge_min and
              byte_size(c) <= @code_challenge_max,
       do: :ok

  defp validate_code_challenge(_), do: {:error, "invalid code_challenge"}

  defp validate_redirect_uri(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "nexguard-connect"} ->
        :ok

      %URI{scheme: scheme, host: host} when scheme in ~w(http https) ->
        if host in @allowed_loopback_hosts do
          :ok
        else
          {:error, "invalid redirect_uri"}
        end

      _ ->
        {:error, "invalid redirect_uri"}
    end
  end

  defp validate_redirect_uri(_), do: {:error, "invalid redirect_uri"}
end
