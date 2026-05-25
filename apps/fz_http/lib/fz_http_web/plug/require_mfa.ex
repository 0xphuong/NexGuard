defmodule FzHttpWeb.Plug.RequireMFA do
  @moduledoc """
  Blocks API access when the admin has enabled Force MFA and the authenticated
  user has not yet enrolled in any MFA method.
  """
  use FzHttpWeb, :controller
  alias FzHttp.Auth.MFA

  def init(opts), do: opts

  def call(conn, _opts) do
    if FzHttp.Config.fetch_config!(:require_mfa) do
      user = Guardian.Plug.current_resource(conn)

      case MFA.fetch_last_used_method_by_user_id(user.id) do
        {:ok, _method} ->
          conn

        {:error, :not_found} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            403,
            Jason.encode!(%{
              "errors" => %{
                "mfa" => "MFA enrollment required. Please enable MFA before using the API."
              }
            })
          )
          |> halt()
      end
    else
      conn
    end
  end
end
