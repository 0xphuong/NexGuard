defmodule FzHttpWeb.WellKnownControllerTest do
  # async: false — spawns the JwtSigner singleton under its registered name;
  # parallel tests would clash on the name. Also lets the supervised child
  # reach the test's sandbox transaction (shared mode).
  use FzHttpWeb.ConnCase, async: false

  alias FzHttp.L7.JwtSigner

  setup do
    start_supervised!({JwtSigner, name: JwtSigner})
    :ok
  end

  describe "GET /.well-known/jwks.json" do
    test "returns 200 with a JWKS-shaped body", %{unauthed_conn: conn} do
      resp = get(conn, ~p"/.well-known/jwks.json")
      body = json_response(resp, 200)

      assert %{"keys" => [jwk]} = body
      assert jwk["kid"] == JwtSigner.active_kid()
      assert jwk["kty"] == "RSA"
      assert jwk["alg"] == "RS256"
      assert jwk["use"] == "sig"
      assert jwk["e"] == "AQAB"
      assert is_binary(jwk["n"])
    end

    test "sends Cache-Control: public, max-age=300", %{unauthed_conn: conn} do
      resp = get(conn, ~p"/.well-known/jwks.json")

      assert ["public, max-age=300"] = get_resp_header(resp, "cache-control")
    end

    test "exposes active + grace keys after a rotation", %{unauthed_conn: conn} do
      old_kid = JwtSigner.active_kid()
      {:ok, new_kid} = JwtSigner.rotate(nil, nil)

      %{"keys" => keys} = json_response(get(conn, ~p"/.well-known/jwks.json"), 200)
      kids = Enum.map(keys, & &1["kid"])

      assert new_kid in kids
      assert old_kid in kids
      assert length(kids) == 2
    end

    test "endpoint is reachable without authentication", %{unauthed_conn: conn} do
      # :api_public pipeline has no auth plug — confirm by hitting the route
      # without any session/cookie/bearer and still getting 200.
      assert %{status: 200} = get(conn, ~p"/.well-known/jwks.json")
    end
  end
end
