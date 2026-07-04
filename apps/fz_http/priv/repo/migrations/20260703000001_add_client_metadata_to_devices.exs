defmodule FzHttp.Repo.Migrations.AddClientMetadataToDevices do
  use Ecto.Migration

  @moduledoc """
  Track which native client (Windows / macOS / etc.) + which version
  enrolled and last called home. Populated from the
  X-NexGuard-Client-Platform / X-NexGuard-Client-Version headers set by
  the native clients on every authenticated request.

  Passive telemetry only -- no enforcement gate. Nullable columns so
  devices that existed before the header rollout keep working.
  `client_last_seen_at` distinguishes "when we last got a version
  report" from `updated_at` (which changes on any field).
  """
  def change do
    alter table(:devices) do
      add(:client_platform,     :string)
      add(:client_version,      :string)
      add(:client_last_seen_at, :utc_datetime_usec)
    end
  end
end
