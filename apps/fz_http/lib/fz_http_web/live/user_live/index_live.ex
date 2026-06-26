defmodule FzHttpWeb.UserLive.Index do
  @moduledoc """
  Admin /users index. U-A redesign (frontend-design-direction):
    * Stats strip — Identity-domain pulse (total / active 24h /
      MFA % / admin count / break-glass count)
    * MFA column showing icon + last-verified freshness
    * Last activity column = max(sign-in, latest device handshake)
    * Disabled rows visually marked (strike + DISABLED badge)
    * Dropped low-value columns: VPN Status (covered on dashboard
      Zone 5), Created (replaced by Last activity)
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Users

  @page_title "Users"
  @active_window_secs 86_400
  @mfa_stale_days 30

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    with {:ok, users} <- Users.list_users(socket.assigns.subject, hydrate: [:index]) do
      socket =
        socket
        |> assign(:users, users)
        |> assign(:stats, compute_stats(users))
        |> assign(:changeset, Users.change_user())
        |> assign(:page_title, @page_title)

      {:ok, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  # ── Stats strip ────────────────────────────────────────────────

  defp compute_stats(users) do
    now = DateTime.utc_now()
    total = length(users)

    %{
      total:        total,
      active_24h:   Enum.count(users, &active_within?(&1, now, @active_window_secs)),
      mfa_pct:      pct(Enum.count(users, &(&1.mfa_count > 0)), total),
      admin_count:  Enum.count(users, &(&1.role == :admin)),
      break_glass:  Enum.count(users, &(&1.access_scope == :all))
    }
  end

  defp active_within?(user, now, window_secs) do
    last = last_activity(user)
    not is_nil(last) and DateTime.diff(now, last, :second) <= window_secs
  end

  defp pct(_, 0), do: 0
  defp pct(part, total), do: round(part / total * 100)

  # ── Template helpers ───────────────────────────────────────────

  @doc """
  Last activity = whichever is newer between portal sign-in and
  any device handshake. VPN handshake is the strong activity signal
  in a ZTNA context — a user who signs into the portal once a month
  but VPNs daily IS active, not idle.
  """
  def last_activity(%{last_signed_in_at: sign_in, last_handshake: handshake}) do
    [sign_in, handshake]
    |> Enum.reject(&is_nil/1)
    |> case do
      []   -> nil
      list -> Enum.max(list, DateTime)
    end
  end

  @doc """
  MFA status descriptor — drives icon + label + colour state for
  the column. Returns one of :fresh / :stale / :unverified / :none.
    * :fresh      — at least one method used within @mfa_stale_days
    * :stale      — enrolled methods exist but none used recently
    * :unverified — methods enrolled, never verified yet
    * :none       — no MFA method enrolled
  """
  def mfa_state(%{mfa_count: 0}), do: :none
  def mfa_state(%{mfa_last_used: nil}), do: :unverified

  def mfa_state(%{mfa_last_used: %DateTime{} = ts}) do
    days = DateTime.diff(DateTime.utc_now(), ts, :day)
    if days <= @mfa_stale_days, do: :fresh, else: :stale
  end

  def mfa_state(_), do: :none

  def mfa_state_icon(:fresh),      do: "mdi-check-circle"
  def mfa_state_icon(:stale),      do: "mdi-alert-circle-outline"
  def mfa_state_icon(:unverified), do: "mdi-help-circle-outline"
  def mfa_state_icon(:none),       do: "mdi-minus-circle-outline"

  def mfa_state_class(:fresh),      do: "ng-mfa-cell--fresh"
  def mfa_state_class(:stale),      do: "ng-mfa-cell--stale"
  def mfa_state_class(:unverified), do: "ng-mfa-cell--unverified"
  def mfa_state_class(:none),       do: "ng-mfa-cell--none"

  @doc """
  Compact relative-time label — "5m", "3d", "—". Mirrors
  HealthMonitor / Audit log conventions so admins read one cadence
  across surfaces.
  """
  def relative_label(nil), do: "—"

  def relative_label(%DateTime{} = ts) do
    diff = DateTime.diff(DateTime.utc_now(), ts, :second)

    cond do
      diff < 60      -> "now"
      diff < 3600    -> "#{div(diff, 60)}m"
      diff < 86_400  -> "#{div(diff, 3600)}h"
      true            -> "#{div(diff, 86_400)}d"
    end
  end

  def disabled?(%{disabled_at: %DateTime{}}), do: true
  def disabled?(_), do: false
end
