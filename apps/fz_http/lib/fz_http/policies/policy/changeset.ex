defmodule FzHttp.Policies.Policy.Changeset do
  use FzHttp, :changeset
  alias FzHttp.Policies.Policy

  @fields ~w[name description default_action applies_to_all_users]a
  @required_fields ~w[name default_action]a

  def create_changeset(attrs) do
    update_changeset(%Policy{}, attrs)
  end

  def update_changeset(policy, attrs) do
    policy
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 500)
    |> unique_constraint(:name)
  end
end
