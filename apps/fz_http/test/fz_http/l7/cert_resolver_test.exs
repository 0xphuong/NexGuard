defmodule FzHttp.L7.CertResolverTest do
  # Pure function — no DB needed.
  use ExUnit.Case, async: true

  alias FzHttp.L7.CertResolver

  defp cert(sans, opts \\ []) do
    %{
      sans: sans,
      label: Keyword.get(opts, :label, "Cert #{System.unique_integer([:positive])}"),
      not_after:
        Keyword.get(opts, :not_after, DateTime.add(DateTime.utc_now(), 90 * 86_400, :second))
    }
  end

  describe "resolve/2" do
    test "wildcard matches a single label" do
      wild = cert(["*.example.com"])

      assert ^wild = CertResolver.resolve("api.example.com", [wild])
    end

    test "wildcard does NOT match two-label subdomain" do
      # *.example.com covers `api.example.com` but not `a.b.example.com`.
      wild = cert(["*.example.com"])

      assert is_nil(CertResolver.resolve("a.b.example.com", [wild]))
    end

    test "wildcard does NOT match the apex" do
      # *.example.com should NOT match the bare apex `example.com`
      # (PKI convention: wildcard requires at least one label).
      wild = cert(["*.example.com"])

      assert is_nil(CertResolver.resolve("example.com", [wild]))
    end

    test "exact match wins over wildcard" do
      wild  = cert(["*.example.com"],         label: "wild")
      exact = cert(["api.example.com"],       label: "exact")

      assert %{label: "exact"} =
               CertResolver.resolve("api.example.com", [wild, exact])
    end

    test "matching is case-insensitive" do
      wild = cert(["*.Example.COM"])

      assert ^wild = CertResolver.resolve("API.Example.com", [wild])
    end

    test "returns nil when no cert matches" do
      certs = [cert(["*.example.com"]), cert(["foo.bar"])]

      assert is_nil(CertResolver.resolve("nope.invalid", certs))
    end

    test "tie-break by not_after DESC (newer cert wins)" do
      # Same SAN, two certs. Dual-provisioning during renewal — the
      # newer-expiring one should adopt apps so the freshly-rotated
      # material gets traffic.
      older =
        cert(["*.example.com"],
          label: "older",
          not_after: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
        )

      newer =
        cert(["*.example.com"],
          label: "newer",
          not_after: DateTime.add(DateTime.utc_now(), 365 * 86_400, :second)
        )

      assert %{label: "newer"} =
               CertResolver.resolve("api.example.com", [older, newer])

      # Order in the candidate list should not affect the outcome.
      assert %{label: "newer"} =
               CertResolver.resolve("api.example.com", [newer, older])
    end

    test "longer specific SAN beats shorter wildcard" do
      short_wild = cert(["*.com"],                 label: "short")
      long_wild  = cert(["*.example.com"],         label: "long")

      # Both technically match `api.example.com`. The more-specific
      # *.example.com (longer suffix) must win.
      assert %{label: "long"} =
               CertResolver.resolve("api.example.com", [short_wild, long_wild])
    end
  end

  describe "covers?/2" do
    test "exact match" do
      assert CertResolver.covers?("api.example.com",
               cert(["api.example.com"]))
    end

    test "wildcard match" do
      assert CertResolver.covers?("api.example.com",
               cert(["*.example.com"]))
    end

    test "no match" do
      refute CertResolver.covers?("api.example.com",
               cert(["*.other.com"]))
    end
  end

  describe "candidates/2" do
    test "returns all matching certs sorted by specificity then recency" do
      wild  = cert(["*.example.com"],   label: "wild",
                    not_after: DateTime.add(DateTime.utc_now(), 60 * 86_400, :second))
      exact = cert(["api.example.com"], label: "exact",
                    not_after: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second))
      miss  = cert(["foo.bar"],         label: "miss")

      assert [%{label: "exact"}, %{label: "wild"}] =
               CertResolver.candidates("api.example.com", [wild, exact, miss])
    end

    test "returns empty list when nothing matches" do
      assert CertResolver.candidates("api.example.com",
               [cert(["*.other.com"]), cert(["foo.bar"])]) == []
    end
  end
end
