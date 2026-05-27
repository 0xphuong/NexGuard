defmodule FzHttp.AuditLog.RetentionScheduler do
  @moduledoc """
  Runs once per day and deletes audit log entries older than the configured
  retention window. The retention period is read from `FzHttp.Config` at
  purge time, so changes made via the UI take effect on the next daily run.
  """
  use GenServer
  alias FzHttp.AuditLogs
  require Logger

  @interval :timer.hours(24)

  def start_link(_), do: GenServer.start_link(__MODULE__, %{})

  @impl GenServer
  def init(state) do
    :timer.send_interval(@interval, :purge)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:purge, state) do
    days = FzHttp.Config.fetch_config!(:audit_log_retention_days)
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400)
    {count, _} = AuditLogs.purge_before(cutoff)

    if count > 0 do
      Logger.info("[AuditLog] Retention purge: removed #{count} entries older than #{days} days")
    end

    {:noreply, state}
  end
end
