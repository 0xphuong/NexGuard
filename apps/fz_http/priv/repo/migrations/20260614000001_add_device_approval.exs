defmodule FzHttp.Repo.Migrations.AddDeviceApproval do
  use Ecto.Migration

  @doc """
  Admin approval workflow for devices.

  - `status`: "pending" | "approved". Default `"approved"` so existing devices
    remain functional after deploy. New native-client enrollments will be
    explicitly set to `"pending"` in application code; admin-created devices
    via the portal continue to use the default.
  - `approved_at`, `approved_by_id`: audit columns set when admin approves.
  """
  def change do
    alter table(:devices) do
      add :status, :string, null: false, default: "approved"
      add :approved_at, :utc_datetime_usec
      add :approved_by_id, references(:users, type: :uuid, on_delete: :nilify_all)
    end

    create index(:devices, [:status])
  end
end
