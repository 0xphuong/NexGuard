defmodule FzHttp.NativeAuth.NativeAuthCode do
  use FzHttp, :schema

  schema "native_auth_codes" do
    field :code, :string
    field :code_challenge, :string
    field :redirect_uri, :string
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec

    belongs_to :user, FzHttp.Users.User

    timestamps(updated_at: false)
  end
end
