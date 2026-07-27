defmodule FzHttp.Repo.Migrations.AddAppliesToAllUsersToPolicies do
  use Ecto.Migration

  def change do
    # v3.3.0 M6: `applies_to_all_users = true` short-circuits the
    # `users_policies` join. Policy rules materialise as ONE
    # nftables element per destination (`user_id=nil` -> forward
    # chain + global `ip_accept`/`ip_drop` sets), instead of the
    # N-users x N-rules cross product. New users automatically
    # inherit these rules without any assignment step.
    alter table(:policies) do
      add(:applies_to_all_users, :boolean, null: false, default: false)
    end
  end
end
