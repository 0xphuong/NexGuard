defmodule FzHttp.Repo.Migrations.CreateApplications do
  use Ecto.Migration

  @doc """
  L7-managed applications (ADR-007, ADR-014).

  Each row declares an internal hostname that should route through the
  L7 transparent proxy. The bundle service materialises only the rows
  where `enabled = true`; everything else is staged config that won't
  affect the running proxy.

  Cert handling:
    * `cert_source = "upload"` — admin pastes the existing cert and
      private key. Typical for real-DNS hostnames with a Let's Encrypt
      cert; no client-side CA install is required.
    * `cert_source = "step_ca"` — the smallstep internal CA (L7-F)
      issues the leaf. Clients must trust the NexGuard internal CA
      root, which NexGuard Connect provisions via Security.framework
      (L7-G).

  `key_pem` is treated as sensitive at the application layer:
  it must be encrypted before insert (Cloak / similar) and never
  rendered to admin UI. Storing as `:binary` here documents the
  expectation that what hits the column is opaque ciphertext.

  `l7_rules` is a JSON array of rule objects (method, path_prefix,
  action, require_groups, require_mfa_age_seconds) evaluated
  first-match-wins with an implicit default deny — see ADR-008.

  Uniqueness:
    * `hostname` UNIQUE — a hostname routes to exactly one app.
    * `virtual_ip` UNIQUE — VipAllocator (L7-A C-4) guarantees this,
      but the DB constraint is the source of truth.
  """
  def change do
    create table(:applications, primary_key: false) do
      add :id,          :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name,        :string,    null: false
      add :description, :text

      # L7 routing
      add :hostname,    :string, null: false
      add :virtual_ip,  :inet,   null: false
      add :backend,     :string, null: false

      # TLS handling
      add :cert_source, :string,  null: false, default: "upload"
      add :cert_pem,    :text
      add :key_pem,     :binary
      add :tls_mode,    :string,  null: false, default: "terminate"

      # Policy
      add :l7_rules,    :jsonb,   null: false, default: fragment("'[]'::jsonb")

      add :enabled,     :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:applications, [:hostname])
    create unique_index(:applications, [:virtual_ip])
    # Hot path: bundle compile filters by `enabled = true`.
    create index(:applications, [:enabled])
  end
end
