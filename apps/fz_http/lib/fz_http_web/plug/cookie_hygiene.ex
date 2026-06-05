defmodule FzHttpWeb.Plug.CookieHygiene do
  @moduledoc """
  Deletes orphan one-time OIDC cookies (`fz_oidc_state`, `fz_pkce_code_verifier`)
  on every browser request, EXCEPT when the request is the OIDC callback that
  needs to consume them.

  These cookies are short-lived (60s/300s) and only meaningful during the brief
  window between authorization redirect and callback. Earlier versions of the
  app failed to clean them up after consumption, allowing them to linger until
  TTL — and in some browsers, to accumulate as the Cookie header grew, eventually
  tripping Cowboy's `max_header_value_length` and surfacing as HTTP 431.

  Safe to leave permanently: this plug is a no-op when the cookies aren't
  present, and the OIDC callback path is excluded so the live flow still works.
  """
  @behaviour Plug

  import Plug.Conn

  @transient_cookies ["fz_oidc_state", "fz_pkce_code_verifier"]
  @oidc_callback_prefix "/auth/oidc/"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: path} = conn, _opts) do
    if String.starts_with?(path, @oidc_callback_prefix) do
      conn
    else
      conn = fetch_cookies(conn)

      Enum.reduce(@transient_cookies, conn, fn name, acc ->
        if Map.has_key?(acc.req_cookies, name) do
          delete_resp_cookie(acc, name)
        else
          acc
        end
      end)
    end
  end
end
