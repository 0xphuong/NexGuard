defmodule FzHttp.AccessGroups.Membership.Changeset do
  use FzHttp, :changeset
  alias FzHttp.AccessGroups.Membership

  @doc """
  Build a membership row. The (user_id, group_id) pair is unique at
  the DB level via composite PK — `unique_constraint/2` here renders
  that as a friendly Ecto error instead of a raw Postgres exception.
  """
  def create_changeset(attrs) do
    %Membership{}
    |> cast(attrs, [:user_id, :group_id, :source, :added_by_id])
    |> validate_required([:user_id, :group_id])
    |> validate_inclusion(:source, [:manual, :idp_sync])
    |> assoc_constraint(:user)
    |> assoc_constraint(:group)
    |> unique_constraint([:user_id, :group_id],
         name: :user_group_memberships_pkey,
         message: "user is already in this group")
  end
end
