defmodule FzHttp.Policies.Policy do
  use FzHttp, :schema

  schema "policies" do
    field :name, :string
    field :description, :string

    # v4.0.4: this field is now MEANINGFUL only when `is_default =
    # true`, in which case it selects the accept/drop verdict of
    # the catch-all rule (`0.0.0.0/0` + `::/0`) the Policies
    # context synthesises at the end of the effective-rules
    # stream. On non-default rows it's persisted (backwards
    # compatibility with v3.3.0..v4.0.3 records) but not read
    # anywhere -- the UI hides it in the New/Edit Policy modal.
    field :default_action, Ecto.Enum, values: [:drop, :accept], default: :drop

    # v3.3.0 M6. When `true`, rules materialise ONCE with
    # `user_id=nil` (global forward chain + global sets), and
    # `users_policies` is ignored -- new users automatically
    # inherit these rules. Optimises "allow HQ subnet for
    # everyone" from N x rule elements to 1.
    field :applies_to_all_users, :boolean, default: false

    # v4.0.4: exactly one policy per install may have
    # `is_default = true` (enforced by a partial unique index).
    # That policy synthesises the final catch-all rule --
    # semantically equivalent to Firezone's legacy `Denylist`
    # entry at chain end, but as a first-class UI concept
    # instead of "add a rule with destination 0.0.0.0/0". The
    # default policy has no rules of its own; its
    # `default_action` field alone drives the emitted verdict.
    field :is_default, :boolean, default: false

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
