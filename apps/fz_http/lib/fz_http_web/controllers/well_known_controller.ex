defmodule FzHttpWeb.WellKnownController do
  @moduledoc """
  Serves IETF `/.well-known/*` endpoints. Currently only `jwks.json`
  per RFC 8615 + RFC 7517 — the L7 proxy (and any other JWT verifier)
  fetches public signing keys from here to validate
  `X-NexGuard-Identity-Jwt` headers minted by `FzHttp.L7.JwtSigner`.

  Exempt from mTLS by design (see task.md B-29): public keys are not
  sensitive and verifiers need them before any cert handshake.
  """

  use FzHttpWeb, :controller

  alias FzHttp.L7.JwtSigner

  # 5 min cache — matches @grace_size = 3 in JwtSigner so a proxy that
  # cached pre-rotation can still find every key it might encounter in
  # an in-flight JWT until refresh.
  @cache_max_age 300

  def jwks(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age}")
    |> json(%{"keys" => JwtSigner.jwks()})
  end
end
