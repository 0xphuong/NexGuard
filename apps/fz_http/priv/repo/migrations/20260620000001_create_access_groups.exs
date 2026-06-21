defmodule FzHttp.Repo.Migrations.CreateAccessGroups do
  use Ecto.Migration

  @doc """
  Access groups for L7 policy (ADR-014).

  A user belongs to N groups; an application requires M groups; access
  is granted when the intersection is non-empty. `source` distinguishes
  manually-created groups from those that may later be reconciled with
  an external IdP (SCIM). `external_id` is set only when `source` is
  `idp_sync` or `system`.
  """
  def change do
    create table(:access_groups, primary_key: false) do
      add :id,          :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name,        :string,    null: false
      add :description, :text
      add :source,      :string,    null: false, default: "manual"
      add :external_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:access_groups, [:name])

    # Indexed lookup for SCIM reconciliation: find rows that originated
    # from a given IdP group ID.
    create index(:access_groups, [:source, :external_id],
             where: "external_id IS NOT NULL")
  end
end
