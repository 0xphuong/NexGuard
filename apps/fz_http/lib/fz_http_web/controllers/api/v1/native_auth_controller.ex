defmodule FzHttpWeb.API.V1.NativeAuthController do
  @moduledoc """
  JSON endpoints for native client token exchange and refresh.

  Both endpoints are unauthenticated (no Guardian pipeline). Trust is established
  by the presented one-time `code` (PKCE-verified) or `refresh_token` (sha256 lookup).

  - `POST /api/v1/native/token`   — Exchange auth code + PKCE verifier → access + refresh
  - `POST /api/v1/native/refresh` — Rotate refresh token, issue new access token
  """
  use FzHttpWeb, :controller
  require Logger

  alias FzHttp.{AuditLogs, NativeAuth, Users}
  alias FzHttpWeb.Auth.JSON.Authentication

  def token(conn, %{"code" => code, "code_verifier" => verifier})
      when is_binary(code) and is_binary(verifier) do
    case NativeAuth.exchange_code(code, verifier) do
      {:ok, user, _redirect_uri} ->
        issue_tokens(conn, user, "code_exchange")

      {:error, reason} ->
        AuditLogs.log("auth.native.token_exchange",
          ip_address: format_remote_ip(conn.remote_ip),
          result: "failure",
          metadata: %{reason: to_string(reason)}
        )

        send_error(conn, exchange_error_status(reason), to_string(reason))
    end
  end

  def token(conn, _params), do: send_error(conn, :bad_request, "missing_params")

  def refresh(conn, %{"refresh_token" => refresh_token})
      when is_binary(refresh_token) do
    with {:ok, user} <- NativeAuth.validate_refresh_token(refresh_token),
         :ok <- check_vpn_session(user, refresh_token, conn) do
      case NativeAuth.rotate_refresh_token(refresh_token, client_metadata(conn)) do
        {:ok, user, new_refresh} ->
          case Authentication.fz_encode_native_access_token(user) do
            {:ok, access_token, _claims} ->
              AuditLogs.log("auth.native.refresh",
                ip_address: format_remote_ip(conn.remote_ip),
                result: "success",
                metadata: %{user_id: user.id}
              )

              json(conn, build_response(user, access_token, new_refresh))

            {:error, reason} ->
              Logger.error("native access token sign failed", reason: inspect(reason))
              send_error(conn, :internal_server_error, "token_issue_failed")
          end

        {:error, reason} ->
          AuditLogs.log("auth.native.refresh",
            ip_address: format_remote_ip(conn.remote_ip),
            result: "failure",
            metadata: %{reason: inspect(reason)}
          )

          send_error(conn, refresh_error_status(reason), refresh_error_message(reason))
      end
    else
      {:error, :session_expired} ->
        send_error(conn, :unauthorized, "session_expired")

      {:error, reason} ->
        AuditLogs.log("auth.native.refresh",
          ip_address: format_remote_ip(conn.remote_ip),
          result: "failure",
          metadata: %{reason: inspect(reason)}
        )

        send_error(conn, refresh_error_status(reason), refresh_error_message(reason))
    end
  end

  def refresh(conn, _params), do: send_error(conn, :bad_request, "missing_params")

  @doc """
  Revoke a refresh token (sign-out from this device).
  Idempotent — returns 200 regardless of whether the token existed or was already revoked.
  This prevents leaking which tokens have ever been issued.
  """
  def revoke(conn, %{"refresh_token" => refresh_token}) when is_binary(refresh_token) do
    _ = NativeAuth.revoke_refresh_token(refresh_token)

    AuditLogs.log("auth.native.revoke",
      ip_address: format_remote_ip(conn.remote_ip),
      result: "success",
      metadata: %{}
    )

    json(conn, %{ok: true})
  end

  def revoke(conn, _params), do: send_error(conn, :bad_request, "missing_params")

  # ---- helpers ----

  # VPN session policy gate: even with a valid refresh token, force re-auth if the
  # admin-configured `vpn_session_duration` has elapsed since `last_signed_in_at`.
  # Keeps native auto-refresh from circumventing the "Require Auth for VPN Sessions" policy.
  defp check_vpn_session(user, refresh_token, conn) do
    if Users.vpn_session_expired?(user) do
      NativeAuth.revoke_refresh_token(refresh_token)

      AuditLogs.log("auth.native.refresh",
        actor_id: user.id,
        actor_email: user.email,
        ip_address: format_remote_ip(conn.remote_ip),
        result: "failure",
        metadata: %{reason: "session_expired"}
      )

      {:error, :session_expired}
    else
      :ok
    end
  end

  defp issue_tokens(conn, user, source) do
    metadata = client_metadata(conn)

    with {:ok, refresh_token} <- NativeAuth.create_refresh_token(user, metadata),
         {:ok, access_token, _claims} <- Authentication.fz_encode_native_access_token(user) do
      AuditLogs.log("auth.native.token_exchange",
        ip_address: format_remote_ip(conn.remote_ip),
        result: "success",
        metadata: %{user_id: user.id, source: source}
      )

      json(conn, build_response(user, access_token, refresh_token))
    else
      {:error, reason} ->
        Logger.error("native_auth issue_tokens failed", reason: inspect(reason))
        send_error(conn, :internal_server_error, "token_issue_failed")
    end
  end

  defp build_response(user, access_token, refresh_token) do
    %{
      access_token: access_token,
      refresh_token: refresh_token,
      token_type: "Bearer",
      expires_in: Authentication.native_access_ttl_seconds(),
      user: %{
        id: user.id,
        email: user.email,
        role: to_string(user.role)
      }
    }
  end

  defp client_metadata(conn) do
    %{
      "user_agent" => conn |> get_req_header("user-agent") |> List.first(),
      "remote_ip" => format_remote_ip(conn.remote_ip)
    }
  end

  defp send_error(conn, status, error) do
    conn
    |> put_status(status)
    |> json(%{error: error})
  end

  defp exchange_error_status(_), do: :bad_request

  defp refresh_error_status(:not_found), do: :unauthorized
  defp refresh_error_status(:revoked), do: :unauthorized
  defp refresh_error_status(:expired), do: :unauthorized
  defp refresh_error_status(_), do: :bad_request

  defp refresh_error_message(:not_found), do: "invalid_refresh_token"
  defp refresh_error_message(:revoked), do: "refresh_token_revoked"
  defp refresh_error_message(:expired), do: "refresh_token_expired"
  defp refresh_error_message(other), do: inspect(other)
end
