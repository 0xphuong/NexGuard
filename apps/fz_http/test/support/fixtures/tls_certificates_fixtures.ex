defmodule FzHttp.TlsCertificatesFixtures do
  @moduledoc """
  Generates real self-signed RSA / ECDSA certs for L7 cert library
  tests. Uses the X509 dep already in mix.lock — no on-disk OpenSSL
  call, no fixture files to maintain.

  Each helper returns `{cert_pem, key_pem}` for direct passing into
  CertParser, or `cert!/1` to insert a row into `l7_tls_certificates`
  for context / resolver tests.
  """

  alias FzHttp.L7.TlsCertificate
  alias FzHttp.Repo

  @doc """
  Mint a self-signed RSA cert + matching key in PEM form.

  Options:
    * `:bits`         — RSA modulus size (default 2048)
    * `:sans`         — list of dNSName SANs (default [domain])
    * `:cn`           — Common Name (default first san)
    * `:valid_from`   — not_before (default now)
    * `:valid_for`    — validity duration in seconds (default 90 days)
  """
  def rsa_cert(domain, opts \\ []) when is_binary(domain) do
    bits       = Keyword.get(opts, :bits, 2048)
    sans       = Keyword.get(opts, :sans, [domain])
    cn         = Keyword.get(opts, :cn, hd(sans))
    valid_from = Keyword.get(opts, :valid_from, DateTime.utc_now())
    valid_for  = Keyword.get(opts, :valid_for, 90 * 86_400)

    key = X509.PrivateKey.new_rsa(bits)

    cert =
      X509.Certificate.self_signed(
        key,
        "/CN=#{cn}",
        validity:
          X509.Certificate.Validity.new(
            valid_from,
            DateTime.add(valid_from, valid_for, :second)
          ),
        extensions: [
          subject_alt_name:
            X509.Certificate.Extension.subject_alt_name(sans)
        ]
      )

    {X509.Certificate.to_pem(cert), X509.PrivateKey.to_pem(key)}
  end

  @doc """
  Mint a self-signed ECDSA cert + matching EC key. Default curve
  P-256 (secp256r1).
  """
  def ec_cert(domain, opts \\ []) do
    curve = Keyword.get(opts, :curve, :secp256r1)
    sans  = Keyword.get(opts, :sans, [domain])
    cn    = Keyword.get(opts, :cn, hd(sans))

    key = X509.PrivateKey.new_ec(curve)

    cert =
      X509.Certificate.self_signed(key, "/CN=#{cn}",
        extensions: [
          subject_alt_name: X509.Certificate.Extension.subject_alt_name(sans)
        ]
      )

    {X509.Certificate.to_pem(cert), X509.PrivateKey.to_pem(key)}
  end

  @doc """
  Insert a TlsCertificate row directly via Repo. Use when the test
  doesn't care about the Cert Parser / context — just needs a row
  pointing at known SANs.
  """
  def create_certificate(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    domain = Map.get(attrs, "domain", "*.fixture-#{n}.local")

    {pem, key} = rsa_cert(domain, sans: Map.get(attrs, "sans", [domain]))

    final =
      Enum.into(attrs, %{
        "label"       => "Fixture Cert #{n}",
        "pem"         => pem,
        "key"         => key,
        "sans"        => Map.get(attrs, "sans", [domain]),
        "primary_san" => domain,
        "issuer"      => "Self-signed",
        "not_before"  => DateTime.utc_now() |> DateTime.truncate(:microsecond),
        "not_after"   => DateTime.utc_now() |> DateTime.add(90 * 86_400, :second) |> DateTime.truncate(:microsecond)
      })

    {:ok, cert} =
      %TlsCertificate{}
      |> Ecto.Changeset.cast(final, [
        :label, :pem, :key, :sans, :primary_san, :issuer, :not_before, :not_after
      ])
      |> Repo.insert()

    cert
  end
end
