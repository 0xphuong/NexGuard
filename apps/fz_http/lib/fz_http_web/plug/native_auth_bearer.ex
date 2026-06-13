defmodule FzHttpWeb.Plug.NativeAuthBearer do
  @moduledoc """
  Bearer token plug for native clients. Validates the access JWT issued by
  `FzHttpWeb.Auth.JSON.Authentication.fz_encode_native_access_token/1`,
  enforces the `"native"` claim, and assigns the matching user to `conn.assigns[:current_user]`.

  401 with `{error: "<reason>"}` on missing header, invalid JWT, wrong claim shape,
  or unknown user.
  """
  import Plug.Conn
  require Logger

  alias FzHttp.Users
  alias FzHttpWeb.Auth.JSON.Authentication

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- fetch_bearer(conn),
         {:ok, claims} <- Authentication.decode_and_verify(token),
         {:ok, user_id} <- fetch_native_claim(claims),
         {:ok, user} <- Users.fetch_user_by_id(user_id) do
      conn
      |> assign(:current_user, user)
      |> assign(:access_token_claims, claims)
    else
      {:error, reason} ->
        Logger.debug("native bearer rejected: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, ~s({"error":"unauthorized"}))
        |> halt()
    end
  end

  defp fetch_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      ["bearer " <> token] when token != "" -> {:ok, token}
      _ -> {:error, :missing_bearer}
    end
  end

  defp fetch_native_claim(%{"native" => user_id}) when is_binary(user_id), do: {:ok, user_id}
  defp fetch_native_claim(_), do: {:error, :wrong_token_type}
end
