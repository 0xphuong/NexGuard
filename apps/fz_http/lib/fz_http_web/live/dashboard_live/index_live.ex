defmodule FzHttpWeb.DashboardLive.Index do
  @moduledoc """
  Ops dashboard. Answers "is the system healthy right now?" in one
  glance, plus surfaces enough recent-activity context that an admin
  arriving fresh in the morning can see what changed overnight.

  Design direction (frontend-design-direction):
    * Dense + quiet — single-glance scan, no marketing chrome
    * Five zones: hero status → grouped stats → activity feed
      (Phase A); security checks + live VPN sessions land in
      Phase B
    * State drives colour: green/amber/red carry meaning,
      decoration is suppressed
  """
  use FzHttpWeb, :live_view

  alias FzHttp.{
    Users,
    Devices,
    Applications,
    AccessGroups,
    AuditLogs,
    Config,
    HealthMonitor,
    OrgSettings
  }

  alias FzHttp.Auth.MFA
  alias FzHttp.L7.{BundleBuilder, TlsCertificates}

  @page_title "Dashboard"
  @recent_activity_limit 8
  @stale_device_days 30
  @cert_warn_days 30
  @cert_critical_days 7

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, @page_title)
     |> assign_all()}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  # ── Data loading ──────────────────────────────────────────────────

  defp assign_all(socket) do
    subject = socket.assigns.subject
    now = DateTime.utc_now()

    # ── Identity ────────────────────────────────────────────────
    user_count = Users.count()
    users_with_mfa = MFA.count_users_with_mfa_enabled()
    admin_count = Users.count_by_role(:admin)

    # ── Network / devices ──────────────────────────────────────
    device_count = Devices.count()
    active_24h = Devices.count_active_within(86_400)
    active_3min = Devices.count_active_within(180)
    pending_device_count = pending_device_count()
    stale_count = device_count - Devices.count_active_within(@stale_device_days * 86_400)

    # ── L7 ZTNA ─────────────────────────────────────────────────
    l7_enabled? = safe_l7_enabled?()
    apps = safe_apps_list(subject)
    enabled_apps = Enum.count(apps, & &1.enabled)
    # Orphan-enabled: app is `enabled=true` but has zero allowed
    # groups. The proxy fail-closes on this since v3.0.5, so the app
    # is silently unreachable until the admin re-adds a group OR
    # disables the app. Surface it on the dashboard so the silent
    # failure doesn't stay silent.
    orphan_enabled_apps = count_orphan_enabled_apps(apps)
    groups = safe_group_count(subject)
    certs = safe_certs()
    cert_summary = summarise_certs(certs, now)
    bundle = safe_bundle()

    # ── Activity ────────────────────────────────────────────────
    recent_audit = AuditLogs.list_logs() |> Enum.take(@recent_activity_limit)
    today_audit_count = audit_count_today(now)

    # ── Service health ──────────────────────────────────────────
    health = safe_health_snapshot()

    # ── Aggregate hero status ──────────────────────────────────
    alerts = build_alerts(%{
      pending_devices: pending_device_count,
      stale_devices: stale_count,
      cert_summary: cert_summary,
      mfa_pct: pct(users_with_mfa, user_count),
      require_mfa: Config.fetch_config!(:require_mfa),
      health: health,
      bundle: bundle,
      l7_enabled?: l7_enabled?,
      enabled_apps: enabled_apps,
      orphan_enabled_apps: orphan_enabled_apps
    })

    socket
    |> assign(:user_count, user_count)
    |> assign(:users_with_mfa, users_with_mfa)
    |> assign(:mfa_pct, pct(users_with_mfa, user_count))
    |> assign(:admin_count, admin_count)
    |> assign(:device_count, device_count)
    |> assign(:active_24h, active_24h)
    |> assign(:active_3min, active_3min)
    |> assign(:pending_device_count, pending_device_count)
    |> assign(:stale_device_count, stale_count)
    |> assign(:l7_enabled?, l7_enabled?)
    |> assign(:apps_count, length(apps))
    |> assign(:enabled_apps_count, enabled_apps)
    |> assign(:group_count, groups)
    |> assign(:cert_count, length(certs))
    |> assign(:cert_warn_count, cert_summary.warn)
    |> assign(:cert_critical_count, cert_summary.critical)
    |> assign(:bundle, bundle)
    |> assign(:recent_audit, recent_audit)
    |> assign(:today_audit_count, today_audit_count)
    |> assign(:health, health)
    |> assign(:alerts, alerts)
  end

  # ── Aggregation: build the hero status alert list ──────────────

  defp build_alerts(d) do
    []
    |> maybe_alert(d.pending_devices > 0, %{
      severity: :info,
      icon: "mdi-clock-outline",
      label: "#{d.pending_devices} device(s) pending approval",
      href: "/devices"
    })
    |> maybe_alert(d.cert_summary.critical > 0, %{
      severity: :critical,
      icon: "mdi-certificate-outline",
      label: "#{d.cert_summary.critical} cert(s) expiring within 7 days",
      href: "/settings/certificates"
    })
    |> maybe_alert(d.cert_summary.warn > 0 and d.cert_summary.critical == 0, %{
      severity: :warn,
      icon: "mdi-certificate-outline",
      label: "#{d.cert_summary.warn} cert(s) expiring within 30 days",
      href: "/settings/certificates"
    })
    |> maybe_alert(d.cert_summary.expired > 0, %{
      severity: :critical,
      icon: "mdi-alert-octagon-outline",
      label: "#{d.cert_summary.expired} cert(s) EXPIRED",
      href: "/settings/certificates"
    })
    |> maybe_alert(d.mfa_pct < 80 and not d.require_mfa, %{
      severity: :warn,
      icon: "mdi-shield-account-outline",
      label: "MFA coverage #{d.mfa_pct}% (target 100%)",
      href: "/settings/security"
    })
    |> maybe_alert(d.stale_devices > 10, %{
      severity: :info,
      icon: "mdi-laptop-off",
      label: "#{d.stale_devices} stale device(s) (>30 days idle)",
      href: "/devices"
    })
    |> maybe_alert(health_unhealthy?(d.health), %{
      severity: :critical,
      icon: "mdi-server-network-off",
      label: "Service health degraded — #{health_summary(d.health)}",
      href: "/diagnostics/connectivity_checks"
    })
    |> maybe_alert(d.l7_enabled? and d.enabled_apps == 0, %{
      severity: :info,
      icon: "mdi-application-cog-outline",
      label: "L7 enforcement is ON but no apps are enabled — proxy idle",
      href: "/applications"
    })
    |> maybe_alert(d.orphan_enabled_apps.count > 0, %{
      severity: :critical,
      icon: "mdi-shield-off-outline",
      label: orphan_alert_label(d.orphan_enabled_apps),
      href: orphan_alert_href(d.orphan_enabled_apps)
    })
    |> Enum.reverse()
  end

  # Format the orphan-enabled alert. Single app → mention by
  # hostname so the admin knows exactly which one needs a group;
  # multiple → just the count + plural noun.
  defp orphan_alert_label(%{count: 1, first_hostname: host, first_id: _}) do
    "#{host} is enabled but has no allowed groups — currently unreachable"
  end

  defp orphan_alert_label(%{count: n}) do
    "#{n} apps are enabled but have no allowed groups — currently unreachable"
  end

  defp orphan_alert_href(%{count: 1, first_id: id}) when not is_nil(id),
    do: "/applications/#{id}/groups"

  defp orphan_alert_href(_), do: "/applications"

  defp maybe_alert(list, true, alert), do: [alert | list]
  defp maybe_alert(list, _false, _), do: list

  # Hero severity = highest of any alert. Used to colour the banner.
  def hero_severity([]),     do: :ok
  def hero_severity(alerts) do
    cond do
      Enum.any?(alerts, &(&1.severity == :critical)) -> :critical
      Enum.any?(alerts, &(&1.severity == :warn))     -> :warn
      true                                            -> :info
    end
  end

  # ── Defensive wrappers ─────────────────────────────────────────
  # Dashboard MUST NOT crash when an L7 component is mis-bootstrapped
  # (e.g. fresh DB pre-bootstrap, supervisor mid-restart). Every
  # auxiliary call rescues to a sane empty-state value.

  defp safe_l7_enabled? do
    try do OrgSettings.l7_enabled?() rescue _ -> false end
  end

  # Count apps that are `enabled = true` but have zero allowed
  # groups. `list_applications/1` selects an `allowed_group_count`
  # virtual field already, so the check is one Enum.filter without
  # a second query. Returns `%{count, first_hostname, first_id}`
  # so the alert can deep-link to the single offending app's groups
  # tab when there's only one.
  defp count_orphan_enabled_apps(apps) do
    orphans =
      apps
      |> Enum.filter(fn app ->
        app.enabled and (Map.get(app, :allowed_group_count) || 0) == 0
      end)

    case orphans do
      []      -> %{count: 0, first_hostname: nil, first_id: nil}
      [a | _] -> %{count: length(orphans), first_hostname: a.hostname, first_id: a.id}
    end
  end

  defp safe_apps_list(subject) do
    case Applications.list_applications(subject) do
      {:ok, apps} -> apps
      _ -> []
    end
  rescue
    _ -> []
  end

  defp safe_group_count(subject) do
    case AccessGroups.list_groups(subject) do
      {:ok, groups} -> length(groups)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp safe_certs do
    try do TlsCertificates.list_all_for_bundle() rescue _ -> [] end
  end

  defp safe_bundle do
    try do BundleBuilder.current() rescue _ -> nil end
  end

  defp safe_health_snapshot do
    try do
      HealthMonitor.snapshot()
    rescue
      _ -> %{db: :unknown, proxy: :unknown, coredns: :unknown}
    end
  end

  defp pending_device_count do
    import Ecto.Query

    try do
      FzHttp.Devices.Device
      |> where([d], d.status == "pending")
      |> FzHttp.Repo.aggregate(:count, :id)
    rescue
      _ -> 0
    end
  end

  defp audit_count_today(now) do
    import Ecto.Query
    start_of_day = %{now | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}

    try do
      FzHttp.AuditLogs.AuditLog
      |> where([l], l.inserted_at >= ^start_of_day)
      |> FzHttp.Repo.aggregate(:count, :id)
    rescue
      _ -> 0
    end
  end

  defp summarise_certs(certs, now) do
    Enum.reduce(certs, %{expired: 0, critical: 0, warn: 0, healthy: 0}, fn cert, acc ->
      case cert.not_after && DateTime.diff(cert.not_after, now, :day) do
        nil  -> Map.update!(acc, :healthy, &(&1 + 1))
        days when days <= 0                     -> Map.update!(acc, :expired,  &(&1 + 1))
        days when days <= @cert_critical_days   -> Map.update!(acc, :critical, &(&1 + 1))
        days when days <= @cert_warn_days       -> Map.update!(acc, :warn,     &(&1 + 1))
        _                                       -> Map.update!(acc, :healthy,  &(&1 + 1))
      end
    end)
  end

  defp health_unhealthy?(h) do
    Enum.any?([:db, :proxy, :coredns], fn k ->
      Map.get(h, k) in [:down, :degraded]
    end)
  end

  defp health_summary(h) do
    [:db, :proxy, :coredns]
    |> Enum.filter(fn k -> Map.get(h, k) in [:down, :degraded] end)
    |> Enum.map(fn k -> "#{k}:#{Map.get(h, k)}" end)
    |> Enum.join(", ")
  end

  defp pct(_, 0), do: 0
  defp pct(part, total), do: round(part / total * 100)

  # ── Template helpers ──────────────────────────────────────────

  def severity_class(:ok),       do: "ng-hero-status--ok"
  def severity_class(:info),     do: "ng-hero-status--info"
  def severity_class(:warn),     do: "ng-hero-status--warn"
  def severity_class(:critical), do: "ng-hero-status--critical"
  def severity_class(_),         do: "ng-hero-status--ok"

  def severity_icon(:ok),        do: "mdi-check-circle-outline"
  def severity_icon(:info),      do: "mdi-information-outline"
  def severity_icon(:warn),      do: "mdi-alert-outline"
  def severity_icon(:critical),  do: "mdi-alert-octagon-outline"
  def severity_icon(_),          do: "mdi-check-circle-outline"

  def alert_severity_class(:info),     do: "ng-alert-row--info"
  def alert_severity_class(:warn),     do: "ng-alert-row--warn"
  def alert_severity_class(:critical), do: "ng-alert-row--critical"
  def alert_severity_class(_),         do: "ng-alert-row--info"

  def relative_time(%DateTime{} = ts) do
    diff = DateTime.diff(DateTime.utc_now(), ts, :second)

    cond do
      diff < 60     -> "just now"
      diff < 3600   -> "#{div(diff, 60)}m ago"
      diff < 86400  -> "#{div(diff, 3600)}h ago"
      true          -> "#{div(diff, 86400)}d ago"
    end
  end

  def relative_time(_), do: "—"

  def short_action(action) do
    action |> String.split(".") |> List.last() |> String.replace("_", " ")
  end

  def action_category(action), do: action |> String.split(".") |> List.first()

  def bundle_label(nil), do: "no bundle compiled yet"
  def bundle_label(%{version: v, compiled_at: ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> "bundle v#{v} · compiled #{relative_time(dt)}"
      _            -> "bundle v#{v}"
    end
  end

  def bundle_label(_), do: "—"
end
