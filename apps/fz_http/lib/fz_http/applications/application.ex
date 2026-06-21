defmodule FzHttp.Applications.Application do
  use FzHttp, :schema

  schema "applications" do
    field :name,        :string
    field :description, :string

    # L7 routing
    field :hostname,    :string
    field :virtual_ip,  FzHttp.Types.IP
    field :backend,     :string

    # TLS handling
    field :cert_source, Ecto.Enum, values: [:upload, :step_ca], default: :upload
    field :cert_pem,    :string
    # Encrypted at rest. Use Cloak's Encrypted.Binary so the column
    # only ever holds opaque ciphertext on the DB. Plaintext never
    # leaves the app process.
    field :key_pem,     FzHttp.Encrypted.Binary, redact: true
    field :tls_mode,    Ecto.Enum, values: [:terminate, :passthrough], default: :terminate

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
