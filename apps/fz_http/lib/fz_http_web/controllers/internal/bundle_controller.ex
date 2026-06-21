defmodule FzHttpWeb.Internal.BundleController do
  @moduledoc """
  Serves the L7 policy bundle to the proxy (ADR-010, Phase 4).

  Reads the already-compiled bundle directly from
  `FzHttp.L7.BundleBuilder`'s public ETS table — no GenServer hop on
  the hot path. The proxy's expected flow is:

    1. Bootstrap fetch with no headers → 200 + body + ETag + signature
    2. PubSub `{:bundle_updated, v}` from `nexguard:l7:bundle` arrives
    3. Conditional refetch with `If-None-Match: "v<n>"` or
       `?since=<n>` — 304 (cheap) when the proxy is already current,
       200 + new body when not

  The signature is a JWT carried in `X-NexGuard-Bundle-Signature`
  whose `bundle_sha256` claim covers a SHA-256 of the response body.
  Verifying the JWT (against the public JWKS at `/.well-known/jwks.json`)
  + recomputing the hash is the proxy's integrity check.
  """

  use FzHttpWeb, :controller

  alias FzHttp.L7.BundleBuilder

  def show(conn, params) do
    case BundleBuilder.current() do
      nil ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{"error" => "bundle_not_compiled"})

      %{version: version, bundle_json: json, signature: sig} ->
        etag = etag_for(version)

        cond do
          since_satisfied?(params, version) -> send_304(conn, etag, sig)
          etag in get_req_header(conn, "if-none-match") -> send_304(conn, etag, sig)
          true -> send_200(conn, json, etag, sig)
        end
    end
  end

  defp send_200(conn, json, etag, sig) do
    conn
    |> put_resp_header("etag", etag)
    |> put_resp_header("x-nexguard-bundle-signature", sig)
    |> put_resp_content_type("application/json")
    |> send_resp(:ok, json)
  end

  defp send_304(conn, etag, sig) do
    conn
    |> put_resp_header("etag", etag)
    |> put_resp_header("x-nexguard-bundle-signature", sig)
    |> send_resp(:not_modified, "")
  end

  defp etag_for(version), do: ~s("v#{version}")

  # `?since=N` long-poll: proxy says "I have version N already; tell me
  # only if you have something newer." If the current version is <= N,
  # there's nothing newer → 304.
  defp since_satisfied?(%{"since" => raw}, current_version) do
    case Integer.parse(raw) do
      {n, ""} -> current_version <= n
      _ -> false
    end
  end

  defp since_satisfied?(_params, _version), do: false
end
