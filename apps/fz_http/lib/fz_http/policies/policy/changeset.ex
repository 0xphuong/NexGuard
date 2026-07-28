defmodule FzHttp.Policies.Policy.Changeset do
  use FzHttp, :changeset
  alias FzHttp.Policies.Policy

  @fields ~w[name description default_action applies_to_all_users is_default]a
  # v4.0.4: `default_action` stays required so v3.3.0..v4.0.3
  # rows (all of which had this column) migrate forward without
  # a NULL blowup on the changeset; new non-default rows accept
  # the default value silently.
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
    # Catches the Postgres partial unique index violation when a
    # second policy tries to set `is_default = true`. Surfaces
    # as a friendly field error instead of an Ecto.ConstraintError
    # crashing the LiveView.
    |> unique_constraint(:is_default, name: :policies_only_one_default,
        message: "another default policy already exists")
  end

  @doc """
  Dedicated changeset for the "Default Policy" edit form. Locks
  `is_default = true` + `applies_to_all_users = true` so admins
  can't accidentally clear the flag or scope the default to a
  subset of users -- both would collapse the catch-all's
  semantics.
  """
  def default_policy_changeset(policy \\ %Policy{}, attrs) do
    attrs =
      attrs
      |> Map.put("is_default", true)
      |> Map.put("applies_to_all_users", true)
      # UI doesn't collect a name for the default row; pin one
      # so `unique_constraint(:name)` doesn't fail on empty.
      |> Map.put_new("name", "__default__")

    update_changeset(policy, attrs)
  end
end
