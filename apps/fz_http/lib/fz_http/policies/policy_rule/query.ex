defmodule FzHttp.Policies.PolicyRule.Query do
  use FzHttp, :query

  def all do
    from(rules in FzHttp.Policies.PolicyRule, as: :policy_rules)
  end

  def by_id(queryable \\ all(), id) do
    where(queryable, [policy_rules: r], r.id == ^id)
  end

  def by_policy_id(queryable \\ all(), policy_id) do
    where(queryable, [policy_rules: r], r.policy_id == ^policy_id)
  end

  def by_empty_port_type(queryable \\ all()) do
    where(queryable, [policy_rules: r], is_nil(r.port_type))
  end
end
