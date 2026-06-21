defmodule FzHttpWeb.Internal.BundleControllerTest do
  # async: false — JwtSigner + BundleBuilder are registered under
  # canonical names so the controller can reach them; parallel tests
  # would collide on those names.
  use FzHttpWeb.ConnCase, async: false

  alias FzHttp.L7.{BundleBuilder, JwtSigner}

  setup do
    start_supervised!({JwtSigner, name: JwtSigner})

    # Default ETS table so the controller's `BundleBuilder.current/0`
    # (no-arg → @default_table) sees what this test writes.
    start_supervised!(
      {BundleBuilder, name: BundleBuilder, subscribe: false, compile_on_boot: false}
    )

    :ok
  end

  describe "GET /internal/bundle.json — empty state" do
    test "returns 503 when no bundle has been compiled yet", %{unauthed_conn: conn} do
      resp = get(conn, ~p"/internal/bundle.json")
      assert %{"error" => "bundle_not_compiled"} = json_response(resp, 503)
    end
  end

  describe "GET /internal/bundle.json — happy path" do
    setup do
      {:ok, version} = BundleBuilder.compile_now()
      {:ok, version: version}
    end

    test "returns the bundle body with signature + ETag headers",
         %{unauthed_conn: conn, version: version} do
      resp = get(conn, ~p"/internal/bundle.json")
      body = json_response(resp, 200)

      assert body["bundle_version"] == version
      assert body["schema_version"] == 1

      [etag] = get_resp_header(resp, "etag")
      assert etag == ~s("v#{version}")

      [sig] = get_resp_header(resp, "x-nexguard-bundle-signature")
      assert is_binary(sig) and byte_size(sig) > 0
    end

    test "the signature verifies and covers SHA-256 of the body",
         %{unauthed_conn: conn} do
      resp = get(conn, ~p"/internal/bundle.json")
      [sig] = get_resp_header(resp, "x-nexguard-bundle-signature")

      assert {:ok, claims} = JwtSigner.verify(sig)

      expected = :crypto.hash(:sha256, resp.resp_body) |> Base.encode16(case: :lower)
      assert claims["bundle_sha256"] == expected
    end

    test "If-None-Match matching the current ETag returns 304",
         %{unauthed_conn: conn, version: version} do
      etag = ~s("v#{version}")

      resp =
        conn
        |> put_req_header("if-none-match", etag)
        |> get(~p"/internal/bundle.json")

      assert response(resp, 304) == ""
      assert get_resp_header(resp, "etag") == [etag]
    end

    test "If-None-Match with a stale ETag falls through to 200",
         %{unauthed_conn: conn} do
      resp =
        conn
        |> put_req_header("if-none-match", ~s("v0"))
        |> get(~p"/internal/bundle.json")

      assert %{"bundle_version" => _} = json_response(resp, 200)
    end

    test "?since=N where N >= current_version returns 304",
         %{unauthed_conn: conn, version: version} do
      resp = get(conn, ~p"/internal/bundle.json?since=#{version}")
      assert response(resp, 304) == ""

      resp_ahead = get(conn, ~p"/internal/bundle.json?since=#{version + 5}")
      assert response(resp_ahead, 304) == ""
    end

    test "?since=N where N < current_version returns 200 with the new body",
         %{unauthed_conn: conn} do
      resp = get(conn, ~p"/internal/bundle.json?since=0")
      assert %{"bundle_version" => _} = json_response(resp, 200)
    end

    test "ignores garbage ?since= and serves the body", %{unauthed_conn: conn} do
      resp = get(conn, ~p"/internal/bundle.json?since=not-a-number")
      assert %{"bundle_version" => _} = json_response(resp, 200)
    end

    test "ETag changes after a recompile", %{unauthed_conn: conn, version: v1} do
      [etag_before] = get_resp_header(get(conn, ~p"/internal/bundle.json"), "etag")
      assert etag_before == ~s("v#{v1}")

      {:ok, v2} = BundleBuilder.compile_now()

      [etag_after] = get_resp_header(get(conn, ~p"/internal/bundle.json"), "etag")
      assert etag_after == ~s("v#{v2}")
      refute etag_before == etag_after
    end
  end
end
