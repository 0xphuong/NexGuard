defmodule FzHttp.NativeAuth.NativeRefreshToken do
  use FzHttp, :schema

  schema "native_refresh_tokens" do
    field :token_hash, :string
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :client_metadata, :map, default: %{}

    belongs_to :user, FzHttp.Users.User

    timestamps(updated_at: false)
  end
end
