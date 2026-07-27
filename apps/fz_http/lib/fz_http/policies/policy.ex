defmodule FzHttp.Policies.Policy do
  use FzHttp, :schema

  schema "policies" do
    field :name, :string
    field :description, :string

    # `default_action` is currently informational -- fz_wall's global
    # default is set by the interface configuration ("drop"), and
    # policy-derived rules just add explicit accepts / drops on top.
    # Persisted so a future release can key per-user default-action
    # off the highest-priority policy the user is in without a
    # schema change.
    field :default_action, Ecto.Enum, values: [:drop, :accept], default: :drop

    # v3.3.0 M6. When `true`, rules materialise ONCE with
    # `user_id=nil` (global forward chain + global sets), and
    # `users_policies` is ignored -- new users automatically
    # inherit these rules. Optimises "allow HQ subnet for
    # everyone" from N x rule elements to 1.
    field :applies_to_all_users, :boolean, default: false

    has_many :rules, FzHttp.Policies.PolicyRule,
      foreign_key: :policy_id,
      on_delete: :delete_all,
      on_replace: :delete

    many_to_many :users, FzHttp.Users.User,
      join_through: "users_policies",
      on_replace: :delete

    timestamps()
  end
end
