defmodule FzHttp.Repo.Migrations.CreateOrgSettings do
  use Ecto.Migration

  @doc """
  Single-row table for org-level toggles. Currently holds only
  `l7_enabled` — the kill switch for the entire L7 subsystem
  (ADR-014). Future booleans / scalars join this row rather than
  spawning new tables.

  Single-row is enforced via a CHECK constraint on `id = 1`. The seed
  insert in `change/0` guarantees `FzHttp.OrgSettings.get/0` can
  always return a row without nil-checking; the corresponding DELETE
  in the rollback restores the previous state.
  """
  def change do
    create table(:org_settings, primary_key: false) do
      add :id,         :integer, primary_key: true, default: 1
      add :l7_enabled, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:org_settings, :singleton, check: "id = 1")

    execute(
      "INSERT INTO org_settings (id, l7_enabled, inserted_at, updated_at) VALUES (1, false, now(), now())",
      "DELETE FROM org_settings WHERE id = 1"
    )
  end
end
