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
  Deployment environment label for the topnav badge.

  Reads `NEXGUARD_ENV` at runtime — operators set it in `.env` per
  deployment (e.g. `NEXGUARD_ENV=PROD` / `STAGING` / `DEV`). When
  unset, falls back to `LOCAL` so dev machines aren't mislabelled
  as prod.
  """
  def nexguard_env do
    System.get_env("NEXGUARD_ENV", "LOCAL") |> String.upcase()
  end

  @doc "CSS modifier for the env badge — picks the right colour ramp."
  def nexguard_env_class do
    case nexguard_env() do
      "PROD"    -> "ng-env-badge--prod"
      "STAGING" -> "ng-env-badge--staging"
      "DEV"     -> "ng-env-badge--dev"
      "LOCAL"   -> "ng-env-badge--local"
      _         -> "ng-env-badge--other"
    end
  end

  @doc """
  Current L7 enforcement state for the topnav dot. Wrapped in a
  `rescue` so a Repo / OrgSettings hiccup never crashes the layout
  render — the dot just goes :unknown.
  """
  def l7_enforcement_status do
    try do
      if FzHttp.OrgSettings.l7_enabled?(), do: :on, else: :off
    rescue
      _ -> :unknown
    end
  end

  @doc """
  Latest policy bundle summary for the topnav: returns
  `{:ok, version, age_seconds}` if compiled, `:none` otherwise.
  Same rescue posture as `l7_enforcement_status/0` — the layout
  must never crash because of an ETS / GenServer hiccup.
  """
  def bundle_status do
    try do
      case FzHttp.L7.BundleBuilder.current() do
        %{version: v, compiled_at: ts} -> {:ok, v, age_seconds(ts)}
        _                              -> :none
      end
    rescue
      _ -> :none
    end
  end

  # Render `Nm` / `Nh` / `Nd` from a seconds-old age.
  def humanise_age(seconds) when seconds < 60,      do: "<1m"
  def humanise_age(seconds) when seconds < 3_600,   do: "#{div(seconds, 60)}m"
  def humanise_age(seconds) when seconds < 86_400,  do: "#{div(seconds, 3_600)}h"
  def humanise_age(seconds),                        do: "#{div(seconds, 86_400)}d"

  defp age_seconds(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _}  -> DateTime.diff(DateTime.utc_now(), dt, :second) |> max(0)
      _             -> 0
    end
  end

  defp age_seconds(_), do: 0
end
