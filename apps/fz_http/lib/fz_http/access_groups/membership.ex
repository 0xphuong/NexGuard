defmodule FzHttp.AccessGroups.Membership do
  use FzHttp, :schema

  @primary_key false
  # Composite PK is enforced at the DB layer (migration). Ecto needs
  # this `@primary_key false` + per-field `primary_key: true` flags
  # so it knows membership rows are identified by (user_id, group_id).
  schema "user_group_memberships" do
    belongs_to :user,     FzHttp.Users.User,            primary_key: true
    belongs_to :group,    FzHttp.AccessGroups.Group,    primary_key: true
    belongs_to :added_by, FzHttp.Users.User,            foreign_key: :added_by_id

    field :source, Ecto.Enum, values: [:manual, :idp_sync], default: :manual

    # Memberships are immutable (delete-and-recreate). No updated_at.
    timestamps(updated_at: false)
  end
end
