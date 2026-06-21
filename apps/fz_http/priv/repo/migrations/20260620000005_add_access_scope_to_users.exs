defmodule FzHttp.Repo.Migrations.AddAccessScopeToUsers do
  use Ecto.Migration

  @doc """
  `access_scope` controls whether a user is subject to per-app group
  checks at the L7 proxy (ADR-008, ADR-014).

  * `"limited"` (default) — normal behaviour, group intersection
    required for access to managed apps.
  * `"all"` — bypass the per-app group check. Effectively a super-pass.
    Reserved for break-glass admins; set only via explicit admin action,
    audited.

  Default `"limited"` means the schema change is safe to deploy ahead
  of L7 enforcement going live — existing users gain no new access.
  """
  def change do
    alter table(:users) do
      add :access_scope, :string, null: false, default: "limited"
    end

    create index(:users, [:access_scope], where: "access_scope = 'all'")
  end
end
