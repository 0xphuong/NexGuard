defmodule FzHttp.Repo.Migrations.CreateUserGroupMemberships do
  use Ecto.Migration

  @doc """
  M:N join between users and access_groups with provenance.

  Composite PK on `(user_id, group_id)` enforces "a user belongs to a
  group at most once". `source` (`manual` / `idp_sync`) lets us
  distinguish memberships managed by humans vs by SCIM reconciliation —
  the SCIM sync job must not blow away manual memberships.

  `added_by_id` is nullable + nilify_all so the actor row can be
  deleted without orphaning the membership history.
  """
  def change do
    create table(:user_group_memberships, primary_key: false) do
      add :user_id,
        references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false

      add :group_id,
        references(:access_groups, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false

      add :source,     :string, null: false, default: "manual"
      add :added_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      # Only inserted_at — memberships are immutable; deletes go through
      # delete_member, not update.
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    # Reverse-direction lookup: who is in group X?
    create index(:user_group_memberships, [:group_id])
  end
end
