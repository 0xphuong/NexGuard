defmodule FzHttp.Repo.Migrations.AddAuditLogRetentionDaysToConfigurations do
  use Ecto.Migration

  def change do
    alter table(:configurations) do
      add :audit_log_retention_days, :integer, default: 90, null: false
    end
  end
end
