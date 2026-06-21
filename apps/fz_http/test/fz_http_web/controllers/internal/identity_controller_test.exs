defmodule FzHttpWeb.Internal.IdentityControllerTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttp.DevicesFixtures
  alias FzHttp.UsersFixtures

  describe "GET /internal/sessions/by_vpn_ip/:ip" do
    test "returns the identity payload with cache headers", %{unauthed_conn: conn} do
      user = UsersFixtures.create_user_with_role(:unprivileged)
      device = DevicesFixtures.create_device(user: user)
      ipv4 = FzHttp.Types.INET.to_string(device.ipv4)

      resp = get(conn, ~p"/internal/sessions/by_vpn_ip/#{ipv4}")
      body = json_response(resp, 200)

      assert body["user_id"] == user.id
      assert body["email"] == user.email
      assert body["role"] == "unprivileged"
      assert body["access_scope"] == "limited"
      assert body["device_id"] == device.id
      assert body["groups"] == []

      assert ["private, max-age=30"] = get_resp_header(resp, "cache-control")
      assert [etag] = get_resp_header(resp, "etag")
      assert String.starts_with?(etag, "W/\"")
    end

    test "responds 404 with unknown_vpn_ip body when no device matches",
         %{unauthed_conn: conn} do
      resp = get(conn, ~p"/internal/sessions/by_vpn_ip/100.64.99.99")
      assert %{"error" => "unknown_vpn_ip"} = json_response(resp, 404)
    end

    test "responds 404 for an unparseable IP", %{unauthed_conn: conn} do
      resp = get(conn, ~p"/internal/sessions/by_vpn_ip/not-an-ip")
      assert %{"error" => "unknown_vpn_ip"} = json_response(resp, 404)
    end

    test "returns 304 when If-None-Match matches the current ETag",
         %{unauthed_conn: conn} do
      user = UsersFixtures.create_user_with_role(:unprivileged)
      device = DevicesFixtures.create_device(user: user)
      ipv4 = FzHttp.Types.INET.to_string(device.ipv4)

      first = get(conn, ~p"/internal/sessions/by_vpn_ip/#{ipv4}")
      [etag] = get_resp_header(first, "etag")

      second =
        conn
        |> put_req_header("if-none-match", etag)
        |> get(~p"/internal/sessions/by_vpn_ip/#{ipv4}")

      assert response(second, 304) == ""
      assert get_resp_header(second, "etag") == [etag]
    end

    test "ETag changes after user.updated_at moves", %{unauthed_conn: conn} do
      user = UsersFixtures.create_user_with_role(:unprivileged)
      device = DevicesFixtures.create_device(user: user)
      ipv4 = FzHttp.Types.INET.to_string(device.ipv4)

      [etag_before] = get_resp_header(get(conn, ~p"/internal/sessions/by_vpn_ip/#{ipv4}"), "etag")

      user
      |> Ecto.Changeset.change(updated_at: DateTime.utc_now() |> DateTime.add(60, :second))
      |> Repo.update!()

      [etag_after] = get_resp_header(get(conn, ~p"/internal/sessions/by_vpn_ip/#{ipv4}"), "etag")
      refute etag_before == etag_after
    end
  end
end
