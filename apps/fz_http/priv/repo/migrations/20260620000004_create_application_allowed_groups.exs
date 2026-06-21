defmodule FzHttp.Repo.Migrations.CreateApplicationAllowedGroups do
  use Ecto.Migration

  @doc """
  M:N join between applications and access_groups: which groups are
  allowed to reach which apps (ADR-014 group intersection check).

  Composite PK on `(application_id, group_id)` enforces uniqueness.
  Deletions cascade — removing a group or an app cleans the join
  table automatically; the bundle service then rebuilds.
  """
  def change do
    create table(:application_allowed_groups, primary_key: false) do
      add :application_id,
        references(:applications, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false

      add :group_id,
        references(:access_groups, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
    end

    # Reverse-direction lookup: which apps does group X have access to?
    create index(:application_allowed_groups, [:group_id])
  end
end
