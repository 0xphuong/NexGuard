defmodule FzHttp.Repo.Migrations.AddPriorityToPolicyRules do
  use Ecto.Migration

  @moduledoc """
  v4.1.0: explicit rule priority within a policy.

  `policy_rules` transitions from set-based (unordered) to
  chain-based (ordered) emission. Priority is an integer 0..9999
  where LOWER = evaluated FIRST (matches iptables sequence-number,
  AWS NACL rule#, GCP firewall priority conventions).

  Default 100 for every existing row so backfill is meaningful --
  rules that predate this migration all share priority 100 and
  break ties by `inserted_at ASC`. Admins tune conflict resolution
  ("drop 8.8.4.4 above allow 8.8.0.0/16") by lowering the
  drop rule's priority (say 10) or raising the allow's (say 500).
  """

  def change do
    alter table(:policy_rules) do
      add(:priority, :integer, null: false, default: 100)
    end

    create(index(:policy_rules, [:policy_id, :priority]))
  end
end
