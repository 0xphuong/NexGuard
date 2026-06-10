defmodule FzHttp.Repo.Migrations.ClearEpochZeroHandshakes do
  use Ecto.Migration

  # Legacy stats_updater overwrote `devices.latest_handshake` with epoch 0
  # (1970-01-01T00:00:00Z) any time WireGuard returned a freshly-added peer
  # that hadn't completed a handshake yet. The fix in stats_updater.ex now
  # skips the update in that case, but this migration cleans up rows that
  # already got polluted before the fix.
  def up do
    execute("UPDATE devices SET latest_handshake = NULL WHERE latest_handshake < '2000-01-01'")
  end

  def down do
    :ok
  end
end
