defmodule FzHttpWeb.Internal.IdentityController do
  @moduledoc """
  Internal endpoint consumed by the L7 proxy (ADR-010). Given a VPN
  IP, returns the identity payload used to authorize per-app access.

  Cache strategy: `Cache-Control: private, max-age=30` + a weak ETag
  hashed from `user.updated_at`. The proxy hits us at most once per
  30 seconds per connection; group-membership and access-scope changes
  invalidate that cache out-of-band via the `nexguard:l7:identity`
  PubSub topic (Phase 5, B-23) — ETag alone cannot capture those
  because they mutate the join table, not `users.updated_at`.

  Phase 1 mounts this under the placeholder `:api_internal` pipeline
  (currently unauthenticated). Phase 6 (B-26 → B-29) swaps in the
  mTLS plug without any route or controller change.
  """

  use FzHttpWeb, :controller

  alias FzHttp.L7.Identity

  @max_age 30

  def show(conn, %{"ip" => ip}) do
    case Identity.lookup_by_vpn_ip(ip) do
      :not_found ->
        conn
        |> put_status(:not_found)
        |> json(%{"error" => "unknown_vpn_ip"})

      {:ok, identity, %{user_updated_at: ts}} ->
        etag = etag_for(identity, ts)

        if etag in get_req_header(conn, "if-none-match") do
          conn
          |> put_resp_header("etag", etag)
          |> put_resp_header("cache-control", "private, max-age=#{@max_age}")
          |> send_resp(:not_modified, "")
        else
          conn
          |> put_resp_header("etag", etag)
          |> put_resp_header("cache-control", "private, max-age=#{@max_age}")
          |> json(identity)
        end
    end
  end

  defp etag_for(%{user_id: user_id}, %DateTime{} = ts) do
    raw = "#{user_id}:#{DateTime.to_iso8601(ts)}"
    digest = :crypto.hash(:md5, raw) |> Base.encode16(case: :lower)
    ~s(W/"#{digest}")
  end
end
