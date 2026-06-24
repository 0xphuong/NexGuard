defmodule FzHttp.L7.CertParser do
  @moduledoc """
  Parses uploaded TLS material into the shape `FzHttp.L7.TlsCertificate`
  stores (ADR-015) — SANs, expiry, issuer, primary_san — and enforces
  the validation gates: cert ↔ key match, minimum key strength, not
  expired, not near-expiry.

  Pure function over PEM bytes. No DB access; the context calls this
  and stuffs the result into a changeset.

  Reuses the X509 library already in deps (used by
  `FzHttp.Applications.Application.Changeset.parse_cert_subject_names/1`
  before this module existed).
  """

  # OWASP minimum + JOSE baseline. The L7 signing key parser
  # (`proxy/internal/jwt/signer.go`) enforces the same value; aligning
  # the two prevents key-strength mismatches between the JWT signer and
  # the per-app TLS cert.
  @min_rsa_bits 2048

  # Reject certs whose validity window has effectively ended. < 24h
  # remaining is not a useful upload — even if it parses, the proxy will
  # serve it briefly and admins waste a slot. Force them to renew first.
  @min_remaining_seconds 24 * 60 * 60

  @type parsed :: %{
          sans:        [String.t()],
          primary_san: String.t() | nil,
          issuer:      String.t() | nil,
          not_before:  DateTime.t() | nil,
          not_after:   DateTime.t() | nil
        }

  @doc """
  Parse + validate a (cert, key) pair.

  Returns `{:ok, parsed_map}` on success, `{:error, reason}` on any
  failure. `reason` is a short atom or `{atom, detail_string}` —
  callers should pattern-match the atom for changeset error mapping,
  not the human string.
  """
  @spec parse(String.t(), String.t()) :: {:ok, parsed} | {:error, term()}
  def parse(cert_pem, key_pem) when is_binary(cert_pem) and is_binary(key_pem) do
    with {:ok, cert}       <- decode_cert(cert_pem),
         {:ok, key}        <- decode_key(key_pem),
         :ok               <- check_key_matches_cert(key, cert),
         :ok               <- check_key_strength(key),
         {:ok, validity}   <- extract_validity(cert),
         :ok               <- check_not_expired(validity),
         {:ok, sans}       <- extract_sans(cert),
         issuer            <- extract_issuer(cert) do
      {:ok,
       %{
         sans:        sans,
         primary_san: List.first(sans),
         issuer:      issuer,
         not_before:  validity.not_before,
         not_after:   validity.not_after
       }}
    end
  end

  def parse(_, _), do: {:error, :invalid_input}

  # ── decode ──────────────────────────────────────────────────────

  defp decode_cert(pem) do
    try do
      {:ok, X509.Certificate.from_pem!(pem)}
    rescue
      e -> {:error, {:cert_parse, Exception.message(e)}}
    end
  end

  defp decode_key(pem) do
    try do
      {:ok, X509.PrivateKey.from_pem!(pem)}
    rescue
      e -> {:error, {:key_parse, Exception.message(e)}}
    end
  end

  # ── key ↔ cert match ────────────────────────────────────────────

  # Compare the cert's `subjectPublicKey` against the public projection
  # of the private key. Catches the common mistake of pasting the wrong
  # key — silently signing with mismatched material would only surface
  # at TLS handshake time on the proxy.
  defp check_key_matches_cert(key, cert) do
    cert_pub = X509.Certificate.public_key(cert)
    key_pub  = X509.PublicKey.derive(key)

    if cert_pub == key_pub do
      :ok
    else
      {:error, :key_mismatch}
    end
  end

  # ── strength ────────────────────────────────────────────────────

  defp check_key_strength({:RSAPrivateKey, _, modulus, _, _, _, _, _, _, _, _}) do
    bits = byte_size(:binary.encode_unsigned(modulus)) * 8
    if bits >= @min_rsa_bits, do: :ok, else: {:error, {:weak_key, bits}}
  end

  # ECDSA P-256 and above are acceptable; smaller curves (P-192) are
  # rejected by erlang's :crypto in modern releases anyway, but we
  # gate explicitly so the error message is clearer.
  defp check_key_strength({:ECPrivateKey, _, _, {:namedCurve, oid}, _, _})
       when oid in [
              {1, 2, 840, 10_045, 3, 1, 7},        # secp256r1 / P-256
              {1, 3, 132, 0, 34},                  # secp384r1
              {1, 3, 132, 0, 35}                   # secp521r1
            ],
       do: :ok

  defp check_key_strength({:ECPrivateKey, _, _, _, _, _}), do: {:error, :weak_curve}

  defp check_key_strength(_), do: {:error, :unsupported_key_type}

  # ── validity window ─────────────────────────────────────────────

  defp extract_validity(cert) do
    {:Validity, not_before, not_after} = X509.Certificate.validity(cert)

    with {:ok, nb} <- x509_time_to_datetime(not_before),
         {:ok, na} <- x509_time_to_datetime(not_after) do
      {:ok, %{not_before: nb, not_after: na}}
    end
  end

  defp check_not_expired(%{not_after: not_after}) do
    now = DateTime.utc_now()
    remaining = DateTime.diff(not_after, now, :second)

    cond do
      remaining <= 0 -> {:error, :expired}
      remaining < @min_remaining_seconds -> {:error, :expires_too_soon}
      true -> :ok
    end
  end

  # X509 lib returns either {:utcTime, charlist} or {:generalTime, charlist}.
  # Both are zulu strings (`YYYYMMDDhhmmssZ` or `YYMMDDhhmmssZ`).
  defp x509_time_to_datetime({:utcTime, charlist}) do
    # YY → assume 20YY (post-2000) which is true for any cert the proxy
    # will accept (we already reject expired material above, and 1999
    # certs are long dead).
    case to_string(charlist) do
      <<yy::binary-size(2), mm::binary-size(2), dd::binary-size(2),
        hh::binary-size(2), mi::binary-size(2), ss::binary-size(2), "Z">> ->
        iso = "20#{yy}-#{mm}-#{dd}T#{hh}:#{mi}:#{ss}Z"
        DateTime.from_iso8601(iso) |> ok_only_datetime()

      _ ->
        {:error, :bad_time_format}
    end
  end

  defp x509_time_to_datetime({:generalTime, charlist}) do
    case to_string(charlist) do
      <<yyyy::binary-size(4), mm::binary-size(2), dd::binary-size(2),
        hh::binary-size(2), mi::binary-size(2), ss::binary-size(2), "Z">> ->
        iso = "#{yyyy}-#{mm}-#{dd}T#{hh}:#{mi}:#{ss}Z"
        DateTime.from_iso8601(iso) |> ok_only_datetime()

      _ ->
        {:error, :bad_time_format}
    end
  end

  # X.509 validity timestamps are second-precision (`...Z`), but the
  # `l7_tls_certificates.not_after` column is `:utc_datetime_usec`
  # (microsecond precision is the project convention to match other
  # timestamp columns). Force precision 6 with value 0 so Ecto's
  # dumper doesn't refuse with "expects microsecond precision".
  defp ok_only_datetime({:ok, dt, _offset}),
    do: {:ok, %{dt | microsecond: {0, 6}}}

  defp ok_only_datetime(other), do: other

  # ── SAN extraction ─────────────────────────────────────────────

  defp extract_sans(cert) do
    sans_ext = X509.Certificate.extension(cert, :subject_alt_name)
    sans = sans_to_strings(sans_ext)
    cn   = cert |> X509.Certificate.subject() |> common_name()

    # CN is duplicative of the SANs in modern certs (and ignored by
    # browsers anyway), but include it as fallback if SANs are empty.
    all =
      [cn | sans]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    case all do
      [] -> {:error, :no_san_or_cn}
      _  -> {:ok, all}
    end
  end

  defp sans_to_strings(nil), do: []

  defp sans_to_strings({:Extension, _oid, _critical, sans}) do
    Enum.flat_map(sans, fn
      {:dNSName, charlist} -> [to_string(charlist)]
      _                    -> []
    end)
  end

  defp common_name({:rdnSequence, rdns}) do
    Enum.find_value(rdns, fn rdn ->
      Enum.find_value(rdn, fn
        {:AttributeTypeAndValue, {2, 5, 4, 3}, {_, name}} -> to_string(name)
        _ -> nil
      end)
    end)
  end

  defp common_name(_), do: nil

  # ── issuer ─────────────────────────────────────────────────────

  defp extract_issuer(cert) do
    cert |> X509.Certificate.issuer() |> common_name()
  end
end
