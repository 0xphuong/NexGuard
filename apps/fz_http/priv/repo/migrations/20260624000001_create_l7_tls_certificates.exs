defmodule FzHttp.Repo.Migrations.CreateL7TlsCertificates do
  use Ecto.Migration

  @doc """
  Shared TLS certificate library for L7 apps (ADR-015).

  Each row holds one cert + key pair that one or more L7 applications
  can reference. Admins upload once and every matching app picks it
  up via either an explicit FK (`applications.tls_cert_id`) or runtime
  hostname → SAN auto-match in `FzHttp.L7.CertResolver`.

  Cert renewal is an in-place UPDATE of `pem` / `key` / `sans` /
  `not_after` on the same row — same `id`, no FK cascade, no per-app
  touch.

  Schema notes:

    * `pem` / `key` are `bytea`; the application layer encrypts via
      `FzHttp.Encrypted.Binary` (Cloak), so the DB only ever holds
      ciphertext. Same threat model as `applications.key_pem` and
      `l7_signing_keys.private_pem`.

    * `sans` is a denormalised string array of every DNS SAN
      extracted at parse time (CN + subjectAltName entries). Used by
      `CertResolver` for fast O(1) hostname-suffix match — re-parsing
      PEM on every bundle compile would dominate compile time.

    * `primary_san` is just the first SAN, lifted out for human-facing
      sort / display in the admin UI. Not used by the resolver.

    * `not_after` drives the expiry alerts (background job emails at
      <30d / <7d). Indexed so the daily scan is a single index range.

    * `issuer` is informational only (e.g. "GoGetSSL DV CA"); no
      verification depends on it.
  """
  def change do
    create table(:l7_tls_certificates, primary_key: false) do
      add :id,           :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :label,        :string,    null: false
      add :pem,          :binary,    null: false
      add :key,          :binary,    null: false
      add :sans,         {:array, :string}, null: false, default: []
      add :primary_san,  :string,    null: false
      add :issuer,       :string
      add :not_before,   :utc_datetime_usec
      add :not_after,    :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Labels are human-facing identifiers; admin needs them unique to
    # avoid "which 'wildcard' did I mean" ambiguity on the Replace flow.
    create unique_index(:l7_tls_certificates, [:label])

    # Bundle compile + admin UI both filter by expiry frequently;
    # daily expiry-scan job is just `WHERE not_after < now() + 30d`.
    create index(:l7_tls_certificates, [:not_after])
  end
end
