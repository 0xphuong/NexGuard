defmodule FzHttp.Users.User do
  use FzHttp, :schema

  schema "users" do
    field :role, Ecto.Enum, values: [:unprivileged, :admin]
    field :email, :string
    field :password_hash, :string

    field :last_signed_in_at, :utc_datetime_usec
    field :last_signed_in_method, :string

    field :sign_in_token, :string, virtual: true, redact: true
    field :sign_in_token_hash, :string
    field :sign_in_token_created_at, :utc_datetime_usec

    # Virtual fields
    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true

    # Virtual fields that can be hydrated (see Users.User.Query.hydrate_*)
    field :device_count,    :integer,           virtual: true
    field :last_handshake,  :utc_datetime_usec, virtual: true
    field :mfa_count,       :integer,           virtual: true
    field :mfa_last_used,   :utc_datetime_usec, virtual: true

    has_many :devices, FzHttp.Devices.Device
    has_many :oidc_connections, FzHttp.Auth.OIDC.Connection
    has_many :api_tokens, FzHttp.ApiTokens.ApiToken
    has_many :mfa_methods, FzHttp.Auth.MFA.Method

    # L7 access bypass marker (ADR-008, ADR-014). `:limited` (default)
    # subjects the user to the per-app group intersection check;
    # `:all` bypasses it entirely (break-glass admins). Set only via
    # explicit admin action, audited.
    field :access_scope, Ecto.Enum, values: [:limited, :all], default: :limited

    has_many :group_memberships, FzHttp.AccessGroups.Membership, foreign_key: :user_id

    many_to_many :groups,
      FzHttp.AccessGroups.Group,
      join_through: FzHttp.AccessGroups.Membership,
      join_keys: [user_id: :id, group_id: :id]

    field :disabled_at, :utc_datetime_usec
    timestamps()
  end
end
