defmodule FzHttp.L7.CertParserTest do
  # Pure functions only — no DB needed. async: true for speed.
  use ExUnit.Case, async: true

  alias FzHttp.L7.CertParser
  alias FzHttp.TlsCertificatesFixtures, as: F

  describe "happy path" do
    test "extracts SANs from a wildcard cert" do
      {pem, key} =
        F.rsa_cert("*.example.com",
          sans: ["*.example.com", "example.com"]
        )

      assert {:ok, parsed} = CertParser.parse(pem, key)
      assert "*.example.com" in parsed.sans
      assert "example.com" in parsed.sans
      assert parsed.primary_san in ["*.example.com", "example.com"]
    end

    test "populates not_before / not_after as DateTime" do
      {pem, key} = F.rsa_cert("a.example.com")

      assert {:ok, parsed} = CertParser.parse(pem, key)
      assert %DateTime{} = parsed.not_after
      assert %DateTime{} = parsed.not_before
      # Self-signed validity from fixture is 90 days; well above the
      # ≥24h minimum the parser enforces.
      assert DateTime.diff(parsed.not_after, DateTime.utc_now(), :day) > 80
    end

    test "accepts ECDSA P-256 key" do
      {pem, key} = F.ec_cert("ecdsa.example.com", curve: :secp256r1)

      assert {:ok, _parsed} = CertParser.parse(pem, key)
    end
  end

  describe "rejection — security-critical" do
    test "rejects mismatched key (key from different cert)" do
      {pem, _wrong_key} = F.rsa_cert("a.example.com")
      {_other_pem, key} = F.rsa_cert("b.example.com")

      assert {:error, :key_mismatch} = CertParser.parse(pem, key)
    end

    test "rejects weak RSA key (1024 bits)" do
      {pem, key} = F.rsa_cert("a.example.com", bits: 1024)

      assert {:error, {:weak_key, 1024}} = CertParser.parse(pem, key)
    end

    test "rejects empty PEM input" do
      # No `BEGIN CERTIFICATE` block.
      assert {:error, {:cert_parse, _}} =
               CertParser.parse("not a pem", "also not")
    end

    test "rejects garbage in the key field" do
      {pem, _key} = F.rsa_cert("a.example.com")

      assert {:error, {:key_parse, _}} =
               CertParser.parse(pem, "not a key")
    end

    test "rejects a cert that expires too soon (< 24h)" do
      # Validity ends in 60 minutes — under the minimum_remaining gate.
      {pem, key} =
        F.rsa_cert("soon.example.com",
          valid_from: DateTime.add(DateTime.utc_now(), -1, :hour),
          valid_for: 60 * 60
        )

      assert {:error, :expires_too_soon} = CertParser.parse(pem, key)
    end

    test "rejects a cert that is already expired" do
      # Validity ended 1 day ago.
      {pem, key} =
        F.rsa_cert("expired.example.com",
          valid_from: DateTime.add(DateTime.utc_now(), -10, :day),
          valid_for: 9 * 86_400
        )

      assert {:error, :expired} = CertParser.parse(pem, key)
    end
  end

  describe "SAN normalisation" do
    test "lowercases SANs" do
      {pem, key} =
        F.rsa_cert("MIXED.Example.COM", sans: ["MIXED.Example.COM"])

      assert {:ok, %{sans: sans}} = CertParser.parse(pem, key)
      # Parser must downcase — resolver does case-insensitive match
      # against this list, so storing them mixed would break matching.
      assert "mixed.example.com" in sans
    end

    test "deduplicates SANs across CN + subjectAltName" do
      # CN duplicates one of the SANs — parser should uniq.
      {pem, key} =
        F.rsa_cert("a.example.com",
          cn: "a.example.com",
          sans: ["a.example.com", "b.example.com"]
        )

      assert {:ok, %{sans: sans}} = CertParser.parse(pem, key)
      assert sans == Enum.uniq(sans)
    end
  end
end
