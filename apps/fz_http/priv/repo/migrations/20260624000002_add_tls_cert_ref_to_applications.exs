defmodule FzHttp.Repo.Migrations.AddTlsCertRefToApplications do
  use Ecto.Migration

  @doc """
  Wire the new cert library (ADR-015) into the applications table.

    * `tls_cert_id` — optional FK to `l7_tls_certificates`. NULL means
      either (a) `cert_source = :upload` and the cert lives in
      `cert_pem` / `key_pem` (legacy / per-app path), or (b)
      `cert_source = :library` AND auto-match is on (resolver picks
      the cert at bundle compile time from SAN coverage).

    * `tls_auto_match` — boolean knob for the `:library` path. When
      true (default), an app left without an explicit `tls_cert_id`
      auto-adopts whichever library cert covers its hostname with the
      highest specificity. Set false to require an explicit pick.

  `ON DELETE RESTRICT` is intentional: deleting a library cert that
  apps still reference must surface as an error in the UI so the
  admin reassigns first — silent SET NULL would orphan apps.

  The existing `cert_source` enum gains a new value `:library` at the
  application layer (Ecto.Enum). No DB-level enum change is needed —
  `cert_source` is stored as `:string`.
  """
  def change do
    alter table(:applications) do
      add :tls_cert_id,    references(:l7_tls_certificates, type: :binary_id, on_delete: :restrict)
      add :tls_auto_match, :boolean, null: false, default: true
    end

    create index(:applications, [:tls_cert_id])
  end
end
