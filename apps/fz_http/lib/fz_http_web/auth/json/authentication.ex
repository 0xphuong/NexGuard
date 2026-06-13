defmodule FzHttpWeb.Auth.JSON.Authentication do
  @moduledoc """
  API Authentication implementation module for Guardian.
  """
  use Guardian, otp_app: :fz_http

  alias FzHttp.{
    Auth,
    ApiTokens.ApiToken,
    ApiTokens,
    Users
  }

  # Access token TTL cho native clients (1 hour). Refresh handled separately
  # via FzHttp.NativeAuth.rotate_refresh_token/1.
  @native_access_ttl_seconds 3600

  @impl Guardian
  def subject_for_token(%Auth.Subject{actor: {:user, user}}, _claims) do
    {:ok, user.id}
  end

  @impl Guardian
  def resource_from_claims(%{"api" => api_token_id}) do
    with {:ok, %ApiTokens.ApiToken{} = api_token} <-
           ApiTokens.fetch_unexpired_api_token_by_id(api_token_id) do
      subject = Auth.fetch_subject!(api_token, nil, nil)
      {:ok, subject}
    else
      {:error, :not_found} -> {:error, :resource_not_found}
    end
  end

  # Native client tokens carry `"native" => user_id` directly (no api_token row).
  # Lifecycle managed by FzHttp.NativeAuth (refresh + revocation).
  def resource_from_claims(%{"native" => user_id}) do
    with {:ok, %Users.User{} = user} <- Users.fetch_user_by_id(user_id) do
      subject = Auth.fetch_subject!(user, nil, nil)
      {:ok, subject}
    else
      {:error, :not_found} -> {:error, :resource_not_found}
    end
  end

  def fz_encode_and_sign(%ApiToken{} = api_token) do
    claims = %{
      "api" => api_token.id,
      "exp" => DateTime.to_unix(api_token.expires_at)
    }

    subject = Auth.fetch_subject!(api_token, nil, nil)
    Guardian.encode_and_sign(__MODULE__, subject, claims)
  end

  @doc """
  Issue a short-lived access JWT for a native client.
  Returns `{:ok, jwt, claims}` per Guardian convention.
  """
  def fz_encode_native_access_token(%Users.User{} = user) do
    expires_at = DateTime.utc_now() |> DateTime.add(@native_access_ttl_seconds, :second)

    claims = %{
      "native" => user.id,
      "exp" => DateTime.to_unix(expires_at)
    }

    subject = Auth.fetch_subject!(user, nil, nil)
    Guardian.encode_and_sign(__MODULE__, subject, claims)
  end

  def native_access_ttl_seconds, do: @native_access_ttl_seconds

  def get_current_subject(%Plug.Conn{} = conn) do
    __MODULE__.Plug.current_resource(conn)
  end
end
