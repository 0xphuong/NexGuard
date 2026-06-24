defmodule FzHttpWeb.SidebarComponent do
  @moduledoc """
  Admin Sidebar
  """
  use FzHttpWeb, :live_component

  def render(assigns) do
    ~H"""
    <aside class="aside is-placed-left is-expanded is-vertically-scrollable ng-sidebar">

      <%# ── Brand ──────────────────────────────────────── %>
      <div class="aside-tools ng-sidebar-brand">
        <%= live_redirect to: ~p"/dashboard" do %>
          <span class="ng-sidebar-brand-icon">
            <i class="mdi mdi-shield-lock-outline"></i>
          </span>
          <span class="ng-sidebar-brand-name">NexGuard</span>
        <% end %>
      </div>

      <%# ── Navigation ─────────────────────────────────── %>
      <div class="menu is-menu-main ng-sidebar-menu">

        <p class="menu-label ng-sidebar-label">Main</p>
        <ul class="menu-list ng-sidebar-list">
          <li>
            <%= live_redirect(to: ~p"/dashboard", class: nav_class(@path, "/dashboard")) do %>
              <span class="icon"><i class="mdi mdi-view-dashboard-outline"></i></span>
              <span class="menu-item-label">Dashboard</span>
            <% end %>
          </li>
        </ul>

        <%# Configuration = identity / endpoint inventory only. WHO
        %# is allowed on the VPN. WHAT they can reach lives under
        %# Access Control below. %>
        <p class="menu-label ng-sidebar-label">Configuration</p>
        <ul class="menu-list ng-sidebar-list">
          <li>
            <%= live_redirect(to: ~p"/users", class: nav_class(@path, "/users")) do %>
              <span class="icon"><i class="mdi mdi-account-group-outline"></i></span>
              <span class="menu-item-label">Users</span>
            <% end %>
          </li>
          <li>
            <%= live_redirect(to: ~p"/devices", class: nav_class(@path, "/devices")) do %>
              <span class="icon"><i class="mdi mdi-laptop"></i></span>
              <span class="menu-item-label">Devices</span>
            <% end %>
          </li>
        </ul>

        <%# Access Control = every surface that decides "who can
        %# reach what". Two network layers under one roof:
        %#   * Rules         — L3/L4 firewall (CIDR + port + drop/accept)
        %#   * Applications  — L7 identity-aware proxy targets
        %#   * Access Groups — group → app M:N for L7 policy
        %#   * TLS Certs     — shared cert library backing L7 apps
        %#   * L7 Enforcement — master kill switch for the L7 stack
        %#
        %# Ordered top-down by network layer: L3/L4 first, L7 below,
        %# enforcement switch last. Matches the admin's mental model
        %# of "coarse policy → fine policy → flip it on".
        %# %>
        <p class="menu-label ng-sidebar-label">Access Control</p>
        <ul class="menu-list ng-sidebar-list">
          <li>
            <%= live_redirect(to: ~p"/rules", class: nav_class(@path, "/rules")) do %>
              <span class="icon"><i class="mdi mdi-filter-outline"></i></span>
              <span class="menu-item-label">Rules</span>
            <% end %>
          </li>
          <li>
            <%= live_redirect(to: ~p"/applications", class: nav_class(@path, "/applications")) do %>
              <span class="icon"><i class="mdi mdi-application-cog-outline"></i></span>
              <span class="menu-item-label">Applications</span>
            <% end %>
          </li>
          <li>
            <%= live_redirect(to: ~p"/access-groups", class: nav_class(@path, "/access-groups")) do %>
              <%# Distinct from Users' account-group-outline so the two
              %# don't collide at a glance in the sidebar. %>
              <span class="icon"><i class="mdi mdi-account-multiple-check-outline"></i></span>
              <span class="menu-item-label">Access Groups</span>
            <% end %>
          </li>
          <li>
            <%= live_redirect(to: ~p"/settings/certificates", class: nav_class(@path, "/settings/certificates")) do %>
              <span class="icon"><i class="mdi mdi-certificate-outline"></i></span>
              <span class="menu-item-label">TLS Certificates</span>
            <% end %>
          </li>
          <li>
            <%= live_redirect(to: ~p"/settings/l7", class: nav_class(@path, "/settings/l7")) do %>
              <%# shield-key communicates "identity-aware gate" better
              %# than the previous power-button icon. %>
              <span class="icon"><i class="mdi mdi-shield-key-outline"></i></span>
              <span class="menu-item-label">L7 Enforcement</span>
            <% end %>
          </li>
        </ul>

        <%# Settings = everything that isn't a daily L7 op: server
        %# defaults, auth providers, customization, account, audit. %>
        <p class="menu-label ng-sidebar-label">Settings</p>
        <ul class="menu-list ng-sidebar-list">
          <li>
            <%= live_redirect(to: ~p"/settings/client_defaults", class: nav_class(@path, "/settings/client_defaults")) do %>
              <span class="icon"><i class="mdi mdi-tune-variant"></i></span>
              <span class="menu-item-label">Client Defaults</span>
            <% end %>
          </li>
          <li>
            <%= live_redirect(to: ~p"/settings/network", class: nav_class(@path, "/settings/network")) do %>
              <span class="icon"><i class="mdi mdi-router-network"></i></span>
              <span class="menu-item-label">Network</span>
            <% end %>
          </li>
          <li>
            <%= live_redirect(to: ~p"/settings/security", class: nav_class(@path, "/settings/security")) do %>
              <%# Settings → Security covers OIDC / SAML / VPN session
              %# policy — distinct from L7 → L7 Enforcement which uses
              %# shield-key for the same icon family but a different
              %# concept (proxy gate vs auth provider config). %>
              <span class="icon"><i class="mdi mdi-lock-outline"></i></span>
              <span class="menu-item-label">Security</span>
            <% end %>
          </li>
          <li>
            <%= live_redirect(to: ~p"/settings/customization", class: nav_class(@path, "/settings/customization")) do %>
              <span class="icon"><i class="mdi mdi-palette-outline"></i></span>
              <span class="menu-item-label">Customization</span>
            <% end %>
          </li>
          <li>
            <%= live_redirect(to: ~p"/settings/account", class: nav_class(@path, "/settings/account")) do %>
              <span class="icon"><i class="mdi mdi-account-circle-outline"></i></span>
              <span class="menu-item-label">Account</span>
            <% end %>
          </li>
          <li>
            <%= live_redirect(to: ~p"/settings/audit_log", class: nav_class(@path, "/settings/audit_log")) do %>
              <span class="icon"><i class="mdi mdi-clipboard-text-clock-outline"></i></span>
              <span class="menu-item-label">Audit Log</span>
            <% end %>
          </li>
        </ul>

        <p class="menu-label ng-sidebar-label">Diagnostics</p>
        <ul class="menu-list ng-sidebar-list">
          <li>
            <%= live_redirect(to: ~p"/diagnostics/connectivity_checks", class: nav_class(@path, "/diagnostics/connectivity_checks")) do %>
              <span class="icon"><i class="mdi mdi-access-point-network"></i></span>
              <span class="menu-item-label">WAN Connectivity</span>
            <% end %>
          </li>
        </ul>

      </div>
    </aside>
    """
  end

  def nav_class(path, prefix) do
    if String.starts_with?(path, prefix) do
      "is-active has-icon"
    else
      "has-icon"
    end
  end
end
