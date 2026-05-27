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
          <li>
            <%= live_redirect(to: ~p"/rules", class: nav_class(@path, "/rules")) do %>
              <span class="icon"><i class="mdi mdi-filter-outline"></i></span>
              <span class="menu-item-label">Rules</span>
            <% end %>
          </li>
        </ul>

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
              <span class="icon"><i class="mdi mdi-shield-key-outline"></i></span>
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
