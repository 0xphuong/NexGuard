defmodule FzHttp.AccessGroups.Group.Changeset do
  use FzHttp, :changeset
  alias FzHttp.AccessGroups.Group

  @permitted ~w[name description source external_id]a
  @required  ~w[name source]a

  @doc """
  Changeset for manual / admin-created groups. Validates name is
  non-empty, descriptive (≥2 chars), and unique. `source` is allowed
  to be `:manual` (default) or `:system`; `idp_sync` groups must go
  through `idp_sync_changeset/2` so we don't accidentally permit a UI
  form to claim IdP provenance.
  """
  def create_changeset(attrs) do
    %Group{}
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_length(:name, min: 2, max: 100)
    |> validate_format(:name, ~r/^[\w\-\. ]+$/,
         message: "must contain only letters, numbers, spaces, dashes, dots, and underscores")
    |> validate_length(:description, max: 500)
    |> validate_inclusion(:source, [:manual, :system],
         message: "manual creation cannot claim idp_sync provenance — use idp_sync_changeset/2")
    |> unique_constraint(:name)
  end

  @doc """
  Changeset for admin updates. `name` and `description` are mutable;
  `source` and `external_id` are immutable to preserve provenance.
  """
  def update_changeset(%Group{} = group, attrs) do
    group
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 100)
    |> validate_length(:description, max: 500)
    |> unique_constraint(:name)
  end

  @doc """
  Changeset for SCIM / IdP reconciliation jobs. Forces `source` to
  `:idp_sync` and requires `external_id`. Not exposed via admin UI.
  """
  def idp_sync_changeset(group_or_struct, attrs) do
    group_or_struct
    |> cast(attrs, [:name, :description, :external_id])
    |> validate_required([:name, :external_id])
    |> put_change(:source, :idp_sync)
    |> unique_constraint(:name)
  end
end
