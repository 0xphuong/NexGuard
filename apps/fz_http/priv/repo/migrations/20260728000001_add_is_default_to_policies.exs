defmodule FzHttp.Repo.Migrations.AddIsDefaultToPolicies do
  use Ecto.Migration

  @moduledoc """
  v4.0.4: introduces the "Default Policy" concept.

  Exactly one row in `policies` may have `is_default = true`; that
  row emits a catch-all rule (`0.0.0.0/0` + `::/0`) at the end of
  the effective-rules stream so the whole set-based nftables
  chain resolves to that action for any traffic not matched by
  a per-user or global regular-policy rule.

  Regular policies keep behaving as before -- rules with per-rule
  actions land in accept/drop sets. The default policy is a
  UI/model refinement, not a firewall-engine change; enforced
  via a partial unique index rather than a NULL-checked
  constraint so admins can freely toggle between "no default"
  (fresh install) and "one default".

  `default_action` on non-default rows becomes UI-irrelevant --
  it's still cast by the changeset (backwards compatibility) but
  only the `is_default = true` row's value gets read at
  emission time.
  """

  def change do
    alter table(:policies) do
      add(:is_default, :boolean, null: false, default: false)
    end

    # Partial unique index: at most one row with is_default = true.
    # Postgres-native way to enforce singleton without a lock table
    # or an app-level check-and-insert race.
    create(
      unique_index(:policies, [:is_default],
        where: "is_default = true",
        name: :policies_only_one_default
      )
    )
  end
end
