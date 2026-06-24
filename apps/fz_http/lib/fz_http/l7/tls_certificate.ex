defmodule FzHttp.L7.TlsCertificate do
  use FzHttp, :schema

  @moduledoc """
  Shared TLS certificate library entry (ADR-015).

  One row = one cert + key pair shared across any number of L7
  applications. Apps either reference it explicitly via
  `applications.tls_cert_id` or are auto-matched by hostname via
  `FzHttp.L7.CertResolver`.

  Renewal: in-place UPDATE of `pem` / `key` / `sans` / `not_after`
  on the SAME `id`. The FK from `applications.tls_cert_id` stays
  valid; apps roll over on the next bundle pivot.

  The `pem` / `key` columns are encrypted at rest via Cloak. Once
  loaded, the struct holds plaintext PEM in memory; never log it or
  echo it back to admin UIs.
  """

  alias FzHttp.Applications.Application

  schema "l7_tls_certificates" do
    field :label,        :string

    # Cloak-encrypted at rest. `redact: true` keeps the field out of
    # any `inspect/2` output — important because LiveView assigns
    # include the struct and would otherwise leak PEM bytes into the
    # diagnostic crash dumps.
    field :pem,          FzHttp.Encrypted.Binary, redact: true
    field :key,          FzHttp.Encrypted.Binary, redact: true

    field :sans,         {:array, :string}, default: []
    field :primary_san,  :string
    field :issuer,       :string
    field :not_before,   :utc_datetime_usec
    field :not_after,    :utc_datetime_usec

    has_many :applications, Application, foreign_key: :tls_cert_id

    timestamps()
  end
end
