defmodule FzHttp.Repo.Migrations.AddCorednsForwardToOrgSettings do
  use Ecto.Migration

  @doc """
  Move CoreDNS forward configuration from `.env`-only into DB-backed
  org settings so admins can edit it via the portal without SSH.

    * `coredns_forward_to`          — list of primary upstream
                                      resolvers, tried in order by
                                      `policy sequential`.
    * `coredns_forward_to_fallback` — additional resolvers appended
                                      AFTER the primary list. Only
                                      consulted when all primaries
                                      fail health check.

  Stored as PostgreSQL `text[]` so the application layer doesn't
  have to parse a comma-separated string at every read. Defaults to
  `'{}'::text[]` (empty) — `FzHttp.Application.bootstrap_dns/0`
  seeds from the legacy env vars on first boot.
  """
  def change do
    alter table(:org_settings) do
      add :coredns_forward_to,          {:array, :string}, null: false, default: []
      add :coredns_forward_to_fallback, {:array, :string}, null: false, default: []
    end
  end
end
