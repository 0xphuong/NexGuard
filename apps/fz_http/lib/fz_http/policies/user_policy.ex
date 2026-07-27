defmodule FzHttp.Policies.UserPolicy do
  @moduledoc """
  Join row between a user and a policy. Composite primary key
  `(user_id, policy_id)` matches the migration -- idempotent
  add is enforced at the DB layer, not the schema level.

  Schema module (rather than raw `"users_policies"` string table
  references) so Ecto knows the two ID columns are `:binary_id`
  and encodes UUID params as 16-byte binaries. Without this,
  `where: up.policy_id in ^uuid_list` sends string UUIDs to the
  Postgres driver, which fails with "expected binary of 16 bytes".
  """
  use FzHttp, :schema

  @primary_key false
  schema "users_policies" do
    belongs_to :user, FzHttp.Users.User, primary_key: true
    belongs_to :policy, FzHttp.Policies.Policy, primary_key: true

    field :inserted_at, :utc_datetime_usec
  end
end
