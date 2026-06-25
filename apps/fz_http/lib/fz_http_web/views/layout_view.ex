defmodule FzHttpWeb.LayoutView do
  use FzHttpWeb, :view
  import FzHttpWeb.Endpoint, only: [static_path: 1]

  @doc """
  Generate a random feedback email to avoid spam.
  """
  def feedback_recipient do
    "feedback@binhphuong.io.vn"
  end

  @doc """
  The application version from mix.exs.
  """
  def application_version do
    Application.spec(:fz_http, :vsn)
  end

  # ── Topnav ops signals (UI-6) ──────────────────────────────────

  @doc """
  Read the latest health snapshot from `FzHttp.HealthMonitor`. The
  monitor polls every 10s and stores a snapshot map; this is just a
  cheap getter. Wrapped in `rescue` so a monitor crash / missing
  GenServer never breaks the layout — falls back to all-unknown.
  """
  def service_health do
    try do
      FzHttp.HealthMonitor.snapshot()
    rescue
      _ -> %{db: :unknown, proxy: :unknown, coredns: :unknown}
    end
  end

  @doc """
  Tooltip for a service dot. Surfaces last-known latency where the
  monitor has one — gives ops a forensic snapshot without leaving the
  page.
  """
  def health_tooltip(service, state, health) do
    name = case service do
      :db -> "Postgres"
      :proxy -> "L7 proxy"
      :coredns -> "CoreDNS"
      other -> Atom.to_string(other)
    end

    base = case state do
      :ok       -> "#{name} reachable"
      :degraded -> "#{name} slow / degraded"
      :down     -> "#{name} unreachable"
      _         -> "#{name} status unknown"
    end

    case Map.get(health, :"#{service}_latency_ms") do
      nil -> base
      ms  -> "#{base} · #{ms}ms"
    end
  end
end
