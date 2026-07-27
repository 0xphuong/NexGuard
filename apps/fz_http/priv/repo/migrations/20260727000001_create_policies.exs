defmodule FzHttp.Repo.Migrations.CreatePolicies do
  @moduledoc """
  Introduces the policy-based egress model. Named policies group
  rules (IP:PORT + action); users are added to policies via a
  join table.

  Additive migration -- the existing `rules` table + its
  per-user rows are left untouched. `Events.set_rules/0` will
  merge policy-derived rules into the flat rule set fed to
  fz_wall, so admins can migrate at their pace. `rules` table
  is scheduled for removal in v4.0.0 (see `task.md`).

  Reuses the existing `action_enum` and `port_type_enum`
  Postgres types (both introduced by `20200228154815` +
  `20220726205646`) so policy rules stay wire-compatible with
  legacy rules when the merged set flows to `FzWall.Server`.
  """
  use Ecto.Migration

  def change do
    # ── policies: named container ──────────────────────────────
    create table(:policies, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false)
      add(:description, :string, default: nil)
      add(:default_action, :action_enum, null: false, default: "drop")

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:policies, [:name]))

    # ── policy_rules: rules inside a policy ────────────────────
    #
    # Mirrors the shape of `rules` (destination + optional
    # port_type/port_range + action). No per-user column here --
    # users get these rules via the users_policies join.
    create table(:policy_rules, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:policy_id, references(:policies, type: :binary_id, on_delete: :delete_all),
        null: false
      )
      add(:destination, :inet, null: false)
      add(:action, :action_enum, null: false, default: "accept")
      add(:port_range, :int4range, default: nil)
      add(:port_type, :port_type_enum, default: nil)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:policy_rules, [:policy_id]))

    # Port fields must come as a pair (same convention as `rules`).
    create(
      constraint("policy_rules", :policy_rule_port_range_needs_type,
        check: "(port_range IS NULL) = (port_type IS NULL)"
      )
    )

    # Port range must be within the valid TCP/UDP port space.
    create(
      constraint("policy_rules", :policy_rule_port_range_is_within_valid_values,
        check: "port_range <@ int4range(1, 65535)"
      )
    )

    # Prevent duplicate (policy, destination, action) with overlapping
    # port ranges. Same GiST exclusion pattern used on the legacy
    # `rules` table for (user_id, destination, action) uniqueness.
    # Split into port-less vs port-typed predicates so that
    # "10.0.0.0/8 accept port-less" doesn't collide with
    # "10.0.0.0/8 accept port 443" inside the same policy.
    execute(
      "ALTER TABLE policy_rules
        ADD CONSTRAINT policy_rule_dest_overlap_excl
        EXCLUDE USING gist (
          policy_id WITH =,
          destination inet_ops WITH &&,
          action WITH =
        )
        WHERE (port_range IS NULL)",
      "ALTER TABLE policy_rules DROP CONSTRAINT policy_rule_dest_overlap_excl"
    )

    execute(
      "ALTER TABLE policy_rules
        ADD CONSTRAINT policy_rule_dest_overlap_excl_port
        EXCLUDE USING gist (
          policy_id WITH =,
          destination inet_ops WITH &&,
          action WITH =,
          port_range WITH &&,
          port_type WITH =
        )
        WHERE (port_range IS NOT NULL)",
      "ALTER TABLE policy_rules DROP CONSTRAINT policy_rule_dest_overlap_excl_port"
    )

    # ── users_policies: many-to-many assignment ────────────────
    #
    # Composite primary key so a user can only be listed under a
    # policy once. Rows are lightweight -- no updated_at (removal
    # + re-add is the only "update" that makes sense here).
    create table(:users_policies, primary_key: false) do
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:policy_id, references(:policies, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("now()")
      )
    end

    create(index(:users_policies, [:policy_id]))
  end
end
