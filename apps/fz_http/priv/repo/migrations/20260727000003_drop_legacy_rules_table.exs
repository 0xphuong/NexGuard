defmodule FzHttp.Repo.Migrations.DropLegacyRulesTable do
  use Ecto.Migration

  @moduledoc """
  v4.0.0: retire the legacy `rules` table.

  Pre-flight guard: if any row still exists, refuse the drop unless
  the operator has explicitly opted into legacy loss via
  `NEXGUARD_ALLOW_LEGACY_RULES_LOSS=true`. Rationale: admin was
  supposed to recreate remaining legacy rules as policies BEFORE
  upgrading (see v3.3.0 CHANGELOG "Removal plan"). This migration
  is a hard boundary: dropping a non-empty rules table on a live
  gateway would silently reopen egress that used to be blocked.

  The `action_enum` and `port_type_enum` Postgres types are NOT
  dropped -- policies + policy_rules still reference them.

  `down/0` recreates the empty shell so a rollback isn't total
  data loss; any legacy rules that WERE in the table are gone
  after this migration -- that's the intended one-way door.
  """

  def up do
    guard_non_empty!()
    drop_if_exists(table(:rules))
  end

  def down do
    create table(:rules) do
      add(:destination, :inet, null: false)
      add(:action, :action_enum, default: "drop", null: false)
      add(:user_id, references(:users, on_delete: :delete_all, type: :binary_id))
      add(:port_type, :port_type_enum, default: nil)
      add(:port_range, :int4range, default: nil)

      timestamps(type: :utc_datetime_usec)
    end
  end

  # A `SELECT count(*) FROM rules` runs against the live DB. If
  # the table is empty, the drop proceeds. If not, the migration
  # fails loudly UNLESS `NEXGUARD_ALLOW_LEGACY_RULES_LOSS=true`
  # is set on the container -- the escape hatch is for operators
  # who genuinely want to abandon their legacy rules (fresh dev
  # instance, staging reset, etc.).
  defp guard_non_empty! do
    override = System.get_env("NEXGUARD_ALLOW_LEGACY_RULES_LOSS") == "true"

    case repo().query("SELECT count(*) FROM rules") do
      {:ok, %{rows: [[0]]}} ->
        :ok

      {:ok, %{rows: [[count]]}} when is_integer(count) ->
        if override do
          IO.puts(
            "[v4.0.0 migration] WARN: dropping non-empty rules table (#{count} row(s)) " <>
              "because NEXGUARD_ALLOW_LEGACY_RULES_LOSS=true"
          )

          :ok
        else
          raise """
          Legacy `rules` table has #{count} row(s). Refusing to drop.

          v4.0.0 removes the legacy per-user firewall rules subsystem.
          Any remaining rows are silently lost when the table is dropped,
          which on a live gateway would reopen egress that used to be
          blocked.

          Recreate the remaining rules as policies via `/policies` BEFORE
          re-running this migration:

            1. Downgrade to v3.3.x, or exec into the current container
            2. For each row, add a policy_rule with the same destination /
               action / port fields under a policy the affected user is
               assigned to (or a `applies_to_all_users=true` policy for
               user_id IS NULL rows).
            3. Verify the policy set matches the intended firewall state
               (`nft list ruleset` on the box) before deleting the legacy
               rows from `rules`.
            4. Re-run the v4.0.0 migration -- guard passes, table drops.

          Escape hatch (only if you really do want to discard these rows):
              docker compose exec nexguard \\
                  env NEXGUARD_ALLOW_LEGACY_RULES_LOSS=true bin/migrate
          """
        end

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        # Table already gone (partial rerun); nothing to guard.
        :ok

      other ->
        raise "v4.0.0 rules table pre-flight failed: #{inspect(other)}"
    end
  end
end
