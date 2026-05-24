defmodule FzHttpWeb.UserLive.VPNStatusComponent do
  @moduledoc """
  Handles VPN status tag.
  """
  use Phoenix.Component

  def status(assigns) do
    user = assigns.user
    expired = assigns.expired

    cond do
      user.disabled_at -> disabled_tag(assigns)
      expired && user.last_signed_in_at -> expired_tag_sign_in(assigns)
      expired && is_nil(user.last_signed_in_at) -> expired_tag_auth(assigns)
      !expired -> enabled_tag(assigns)
    end
  end

  defp disabled_tag(assigns) do
    ~H"""
    <span
      class="ng-status-badge ng-status-badge--disabled"
      title="This user's VPN connection is disabled by an administrator or OIDC refresh failure"
    >
      <i class="mdi mdi-close-circle-outline"></i> Disabled
    </span>
    """
  end

  defp enabled_tag(assigns) do
    ~H"""
    <span class="ng-status-badge ng-status-badge--enabled" title="This user's VPN connection is enabled">
      <i class="mdi mdi-check-circle-outline"></i> Enabled
    </span>
    """
  end

  defp expired_tag_sign_in(assigns) do
    ~H"""
    <span
      class="ng-status-badge ng-status-badge--expired"
      title="This user's VPN connection is disabled due to authentication expiration"
    >
      <i class="mdi mdi-clock-alert-outline"></i> Expired
    </span>
    """
  end

  defp expired_tag_auth(assigns) do
    ~H"""
    <span class="ng-status-badge ng-status-badge--expired" title="User must sign in to activate">
      <i class="mdi mdi-clock-alert-outline"></i> Expired
    </span>
    """
  end
end
