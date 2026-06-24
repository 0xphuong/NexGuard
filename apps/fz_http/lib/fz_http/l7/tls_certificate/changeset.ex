defmodule FzHttp.L7.TlsCertificate.Changeset do
  @moduledoc """
  Validation pipeline for `FzHttp.L7.TlsCertificate` (ADR-015).

  Both `create_changeset/1` and `replace_changeset/2` run the uploaded
  PEMs through `FzHttp.L7.CertParser` and lift the parsed values
  (SANs, expiry, issuer, primary_san) onto the changeset. This means
  the schema's denormalised fields are always derived — admin UI
  cannot get into a state where `sans` says one thing and `pem`
  says another.

  Replace = update in place: the SAME row keeps its `id` and the
  changeset overwrites pem/key/sans/expiry/etc. Any app pointing at
  this row through `applications.tls_cert_id` is unaffected at the
  FK level — it sees the new material on the next bundle compile.
  """

  use FzHttp, :changeset

  alias FzHttp.L7.{CertParser, TlsCertificate}

  @permitted ~w[label pem key]a
  @required ~w[label pem key]a

  @doc "Brand new library entry."
  def create_changeset(attrs) do
    %TlsCertificate{}
    |> base_changeset(attrs)
  end

  @doc """
  Replace flow — same record id, new cert material. Label is editable
  on replace too (admins occasionally re-purpose a slot when an issuer
  changes), but pem / key are required so the admin can't accidentally
  "save" an empty form and wipe the old cert.
  """
  def replace_changeset(%TlsCertificate{} = cert, attrs) do
    cert
    |> base_changeset(attrs)
  end

  defp base_changeset(struct_or_cert, attrs) do
    struct_or_cert
    |> cast(attrs, @permitted)
    |> update_change(:label, &normalize_label/1)
    |> validate_required(@required)
    |> validate_length(:label, min: 2, max: 100)
    |> unique_constraint(:label)
    |> parse_and_lift_pem()
  end

  defp normalize_label(nil), do: nil
  defp normalize_label(label) when is_binary(label), do: String.trim(label)

  # Run the PEMs through CertParser and lift the parsed values onto
  # the changeset. Any parser error becomes a changeset error on the
  # offending field — the admin sees "key doesn't match cert" rather
  # than "validation failed" on save.
  defp parse_and_lift_pem(changeset) do
    pem = get_field(changeset, :pem)
    key = get_field(changeset, :key)

    cond do
      not (is_binary(pem) and is_binary(key)) ->
        changeset

      changeset.valid? == false ->
        changeset

      true ->
        case CertParser.parse(pem, key) do
          {:ok, parsed} ->
            changeset
            |> put_change(:sans,        parsed.sans)
            |> put_change(:primary_san, parsed.primary_san)
            |> put_change(:issuer,      parsed.issuer)
            |> put_change(:not_before,  parsed.not_before)
            |> put_change(:not_after,   parsed.not_after)

          {:error, reason} ->
            add_parse_error(changeset, reason)
        end
    end
  end

  # Map CertParser's tagged-tuple errors to user-friendly changeset
  # errors on the appropriate field. Detail strings come straight from
  # the underlying X509 lib so they're as specific as we can be without
  # leaking PEM bytes.
  defp add_parse_error(changeset, :expired),
    do: add_error(changeset, :pem, "certificate is already expired")

  defp add_parse_error(changeset, :expires_too_soon),
    do: add_error(changeset, :pem, "certificate expires in less than 24 hours")

  defp add_parse_error(changeset, :key_mismatch),
    do: add_error(changeset, :key, "private key does not match the certificate")

  defp add_parse_error(changeset, {:weak_key, bits}),
    do:
      add_error(changeset, :key,
        "RSA key is #{bits} bits — minimum is 2048 (regenerate with a stronger key)")

  defp add_parse_error(changeset, :weak_curve),
    do: add_error(changeset, :key, "ECDSA curve too weak — use P-256 or larger")

  defp add_parse_error(changeset, :unsupported_key_type),
    do: add_error(changeset, :key, "only RSA and ECDSA private keys are accepted")

  defp add_parse_error(changeset, :no_san_or_cn),
    do: add_error(changeset, :pem, "certificate has no DNS SAN or CN — cannot match hostnames")

  defp add_parse_error(changeset, :bad_time_format),
    do: add_error(changeset, :pem, "certificate validity timestamps could not be parsed")

  defp add_parse_error(changeset, {:cert_parse, detail}),
    do: add_error(changeset, :pem, "certificate could not be parsed: #{detail}")

  defp add_parse_error(changeset, {:key_parse, detail}),
    do: add_error(changeset, :key, "private key could not be parsed: #{detail}")

  defp add_parse_error(changeset, _other),
    do: add_error(changeset, :pem, "could not validate uploaded TLS material")
end
