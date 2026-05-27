defmodule FzHttp.AuditLog.RetentionScheduler do
  @moduledoc """
  Runs once per day and deletes audit log entries older than the configured
  retention window. Configure via:

      config :fz_http, :audit_log_retention_days, 90
  """
  use GenServer
  alias FzHttp.AuditLogs
  require Logger

  @interval :timer.hours(24)
  @default_retention_days 90

  def start_link(_), do: GenServer.start_link(__MODULE__, %{})

  @impl GenServer
  def init(state) do
    :timer.send_interval(@interval, :purge)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:purge, state) do
    days = Application.get_env(:fz_http, :audit_log_retention_days, @default_retention_days)
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400)
    {count, _} = AuditLogs.purge_before(cutoff)

    if count > 0 do
      Logger.info("[AuditLog] Retention purge: removed #{count} entries older than #{days} days")
    end

    {:noreply, state}
  end
end
