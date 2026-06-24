defmodule FzHttp.Applications.Application do
  use FzHttp, :schema

  schema "applications" do
    field :name,        :string
    field :description, :string

    # L7 routing
    field :hostname,    :string
    field :virtual_ip,  FzHttp.Types.IP
    field :backend,     :string

    # TLS handling. Three sources (ADR-011, ADR-015):
    #   :upload    — admin paste cert + key per app (legacy / per-app)
    #   :step_ca   — internal smallstep CA (reserved; pipeline pending)
    #   :library   — shared cert library; either explicit FK below
    #                or hostname-auto-match via FzHttp.L7.CertResolver
    field :cert_source, Ecto.Enum, values: [:upload, :step_ca, :library], default: :upload
    field :cert_pem,    :string
    # Encrypted at rest. Use Cloak's Encrypted.Binary so the column
    # only ever holds opaque ciphertext on the DB. Plaintext never
    # leaves the app process. (Used by :upload only.)
    field :key_pem,     FzHttp.Encrypted.Binary, redact: true
    field :tls_mode,    Ecto.Enum, values: [:terminate, :passthrough], default: :terminate

    # Cert library wiring (:library source). `tls_cert_id` NULL +
    # `tls_auto_match` true → resolver picks best-matching library cert
    # for `hostname` at bundle compile time. `tls_cert_id` set →
    # explicit pin (used when admin doesn't trust auto-match or when
    # multiple certs could match the same hostname).
    belongs_to :tls_cert, FzHttp.L7.TlsCertificate, type: :binary_id
    field :tls_auto_match, :boolean, default: true

    # First-match-wins policy rules. Schema validated at the
    # changeset layer; default `[]` means no rule yet defined.
    field :l7_rules,    {:array, :map}, default: []

    field :enabled,     :boolean, default: false

    has_many :allowed_group_links,
      FzHttp.Applications.AllowedGroup,
      foreign_key: :application_id,
      on_delete: :delete_all

    many_to_many :allowed_groups,
      FzHttp.AccessGroups.Group,
      join_through: FzHttp.Applications.AllowedGroup

    # Virtual: hydrated by listing helpers (admin UI).
    field :allowed_group_count, :integer, virtual: true

    timestamps()
  end
end
