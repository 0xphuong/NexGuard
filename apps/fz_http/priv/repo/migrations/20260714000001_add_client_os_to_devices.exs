defmodule FzHttp.Repo.Migrations.AddClientOsToDevices do
  use Ecto.Migration

  @moduledoc """
  Extend passive client telemetry with OS-level identification so
  admins can see the actual operating system running behind each
  native client -- macOS release, Windows edition, Linux distro --
  plus the CPU architecture. Populated from three new request
  headers set by native clients on every authenticated call:

      X-NexGuard-Client-OS-Name      → client_os_name
      X-NexGuard-Client-OS-Version   → client_os_version
      X-NexGuard-Client-Arch         → client_arch

  Nullable so devices that enrolled before this rollout keep working
  (they'll simply show "—" until the client hits any auth endpoint
  and repopulates on the next request). Same best-effort philosophy
  as `client_platform` / `client_version`: a failed telemetry write
  never breaks enroll / config flows.
  """
  def change do
    alter table(:devices) do
      add(:client_os_name,    :string)
      add(:client_os_version, :string)
      add(:client_arch,       :string)
    end
  end
end
