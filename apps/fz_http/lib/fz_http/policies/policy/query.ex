defmodule FzHttp.Policies.Policy.Query do
  use FzHttp, :query

  def all do
    from(policies in FzHttp.Policies.Policy, as: :policies)
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [policies: p], p.id == ^id)
  end

  def by_name(queryable \\ all(), name) do
    where(queryable, [policies: p], p.name == ^name)
  end

  @doc """
  Policies the given user is assigned to via the `users_policies`
  join. Reverse view of `list_users_in_policy/2`.
  """
  def by_user_id(queryable \\ all(), user_id) do
    from(p in queryable,
      join: up in FzHttp.Policies.UserPolicy,
      on: up.policy_id == p.id,
      where: up.user_id == ^user_id
    )
  end
end
