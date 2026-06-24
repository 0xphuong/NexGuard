defmodule FzHttp.L7.TlsCertExpiryScanner do
  @moduledoc """
  Daily scan of the cert library for upcoming expiries (ADR-015).

  For every cert in `l7_tls_certificates`:

    * `not_after - now <= 0`     → **expired** — log :error + audit entry
    * `not_after - now <= 7d`    → **critical** — log :warning + audit entry
    * `not_after - now <= 30d`   → **soon** — log :info + audit entry

  Each level writes an audit log entry tagged
  `tls_cert.expiry_warning` so admins reviewing the audit trail after
  an incident can confirm whether the system did warn them. The
  /settings/certificates dashboard is the primary visual surface;
  this scanner is the off-band channel for ops who don't sit in the
  UI daily.

  No email integration here — many self-hosted deployments don't
  configure SMTP, and the existing per-cert info is also in
  `/settings/certificates` (status badge + stat strip). A future
  iteration can layer email on top using the same audit hook
  (subscribe to the action string).

  Idempotency: scans don't write the same warning twice on the same
  day. We dedupe against the most recent audit entry per cert.
  """
  use GenServer
  import Ecto.Query
  require Logger

  alias FzHttp.{AuditLogs, Repo}
  alias FzHttp.L7.TlsCertificate

  @interval :timer.hours(24)

  # On startup, fire after 60s so deploys aren't immediately spammed
  # with warnings before the operator has logged in.
  @initial_delay :timer.seconds(60)

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Test/ops handle to scan now without waiting for the next tick."
  def scan_now, do: GenServer.call(__MODULE__, :scan_now, 30_000)

  @impl GenServer
  def init(state) do
    Process.send_after(self(), :scan, @initial_delay)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:scan, state) do
    do_scan()
    Process.send_after(self(), :scan, @interval)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:scan_now, _from, state) do
    counts = do_scan()
    {:reply, counts, state}
  end

  # ── Scan implementation ────────────────────────────────────────

  defp do_scan do
    now = DateTime.utc_now()
    cutoff_30d = DateTime.add(now, 30 * 86_400, :second)

    # Pull every cert whose not_after is within 30 days OR already
    # past — a single index range over `not_after`.
    certs =
      from(c in TlsCertificate,
        where: c.not_after <= ^cutoff_30d,
        order_by: [asc: c.not_after]
      )
      |> Repo.all()

    counts =
      Enum.reduce(certs, %{expired: 0, critical: 0, soon: 0, skipped: 0}, fn cert, acc ->
        level = classify(cert.not_after, now)

        if level && not already_warned_today?(cert.id, now) do
          emit(level, cert)
          Map.update!(acc, level, &(&1 + 1))
        else
          Map.update!(acc, :skipped, &(&1 + 1))
        end
      end)

    if certs != [] do
      Logger.info(
        "[TlsCertExpiryScanner] swept #{length(certs)} cert(s) near expiry: " <>
          "expired=#{counts.expired} critical=#{counts.critical} soon=#{counts.soon}"
      )
    end

    counts
  end

  defp classify(%DateTime{} = not_after, now) do
    seconds_left = DateTime.diff(not_after, now, :second)

    cond do
      seconds_left <= 0           -> :expired
      seconds_left <= 7 * 86_400  -> :critical
      seconds_left <= 30 * 86_400 -> :soon
      true                        -> nil
    end
  end

  defp classify(_, _), do: nil

  # ── Emit ───────────────────────────────────────────────────────

  defp emit(:expired, cert) do
    Logger.error("[TlsCertExpiryScanner] EXPIRED: #{cert.label} (#{cert.primary_san})")
    audit(cert, :expired)
  end

  defp emit(:critical, cert) do
    days = DateTime.diff(cert.not_after, DateTime.utc_now(), :day)

    Logger.warning(
      "[TlsCertExpiryScanner] CRITICAL: #{cert.label} (#{cert.primary_san}) expires in #{days}d"
    )

    audit(cert, :critical)
  end

  defp emit(:soon, cert) do
    days = DateTime.diff(cert.not_after, DateTime.utc_now(), :day)

    Logger.info(
      "[TlsCertExpiryScanner] expiring soon: #{cert.label} (#{cert.primary_san}) in #{days}d"
    )

    audit(cert, :soon)
  end

  defp audit(cert, level) do
    AuditLogs.log("tls_cert.expiry_warning",
      actor_email: "system",
      target_type: "tls_certificate",
      target_id: cert.id,
      target_label: cert.label,
      metadata: %{
        level: Atom.to_string(level),
        primary_san: cert.primary_san,
        not_after: cert.not_after,
        days_remaining:
          DateTime.diff(cert.not_after, DateTime.utc_now(), :day)
      }
    )
  end

  # Dedupe: did we already write a `tls_cert.expiry_warning` audit
  # entry for this cert in the past 23 hours? (Slight gap under the
  # 24h interval to tolerate clock skew + slow scan start.)
  defp already_warned_today?(cert_id, now) do
    cutoff = DateTime.add(now, -23 * 3600, :second)

    from(l in "audit_logs",
      where: l.action == "tls_cert.expiry_warning",
      where: l.target_id == ^cert_id,
      where: l.inserted_at >= ^cutoff,
      select: 1,
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> false
      _   -> true
    end
  end
end
