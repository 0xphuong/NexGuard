defmodule FzHttp.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  def change do
    create table(:audit_logs, primary_key: false) do
      add :id,          :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      # actor_id nullable: system events + deleted users vẫn giữ được history
      add :actor_id,    references(:users, type: :binary_id, on_delete: :nilify_all), null: true
      # snapshot email tại thời điểm event — không bị mất khi user bị xóa
      add :actor_email, :string
      # dot-notation: "auth.login.success", "user.delete", "config.change" ...
      add :action,      :string, null: false
      # resource bị tác động
      add :target_type, :string
      add :target_id,   :string
      add :target_label,:string
      # client IP — string thay vì inet để tránh dependency Postgrex custom type
      add :ip_address,  :string
      add :result,      :string, null: false, default: "success"
      # extra context tùy action (old_role/new_role, provider_id, ...)
      add :metadata,    :map, default: %{}

      # chỉ inserted_at — audit log là immutable
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # queries theo user
    create index(:audit_logs, [:actor_id])
    # filter theo loại action
    create index(:audit_logs, [:action])
    # time-range queries (phổ biến nhất)
    create index(:audit_logs, [:inserted_at])
    # tìm failure events
    create index(:audit_logs, [:result])
    # filter action + time range cùng lúc (audit page)
    create index(:audit_logs, [:action, :inserted_at])
    # tra cứu history của 1 resource cụ thể
    create index(:audit_logs, [:target_type, :target_id])
  end
end
