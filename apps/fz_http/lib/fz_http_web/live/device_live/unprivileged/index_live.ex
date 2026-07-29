defmodule FzHttpWeb.DeviceLive.Unprivileged.Index do
  @moduledoc """
  Handles Device LiveViews.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.Devices

  @page_title "Your Devices"
  @page_subtitle """
  Each device is one NexGuard Connect endpoint authorised to reach this server.
  """

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    with :ok <- authorize_socket_action(socket),
         {:ok, devices} <-
           Devices.list_devices_for_user(socket.assigns.current_user, socket.assigns.subject) do
      socket =
        socket
        |> assign(:devices, devices)
        |> assign(:page_subtitle, @page_subtitle)
        |> assign(:page_title, @page_title)
        # Install-instructions state. Default `:macos` because it's the
        # most common admin machine; the JS hook `OSDetect` overrides
        # this on mount by inspecting `navigator.userAgent` and pushing
        # `os_detected` back to us.
        |> assign(:install_selected_os, :macos)

      {:ok, socket}
    else
      {:error, {:unauthorized, _context}} ->
        {:ok, not_authorized(socket)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("select_install_os", %{"os" => os}, socket) do
    {:noreply, assign(socket, :install_selected_os, to_os_atom(os))}
  end

  # Fired once at page mount by the `OSDetect` JS hook. Falls back
  # to the current server-side default (macOS) on any parse failure
  # so an exotic user agent doesn't leave the section blank.
  def handle_event("os_detected", %{"os" => os}, socket) do
    {:noreply, assign(socket, :install_selected_os, to_os_atom(os))}
  end

  defp to_os_atom("macos"), do: :macos
  defp to_os_atom("windows"), do: :windows
  defp to_os_atom("linux"), do: :linux
  defp to_os_atom(_), do: :macos

  @doc """
  The install command per OS. Kept in the LiveView (not a config
  file) because these strings are versioned with the UI copy that
  documents them -- changing one without the other would confuse
  a support ticket.
  """
  def install_command(:macos),
    do: "curl -fsSL https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.sh | bash"

  def install_command(:windows),
    do: "irm https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.ps1 | iex"

  def install_command(:linux),
    do:
      "curl -fsSL https://raw.githubusercontent.com/0xphuong/nexguard-releases/main/install.sh | sudo bash"

  @doc """
  Prereq hint shown under the code block. Distinct per OS because
  each has its own privilege-escalation quirk + supported-version
  matrix worth calling out.
  """
  def install_hint(:macos),
    do:
      "Runs interactively — you'll be prompted for your admin password (sudo). macOS 12+ on Intel or Apple Silicon."

  def install_hint(:windows),
    do:
      "Run in an elevated PowerShell prompt (right-click PowerShell → Run as Administrator). Windows 10 22H2 or Windows 11."

  def install_hint(:linux),
    do:
      "Ubuntu 20.04+, Debian 11+, or a systemd-based x86_64 distro. Requires sudo."

  defp authorize_socket_action(%{assigns: %{live_action: :new}} = socket) do
    Devices.authorize_user_device_management(socket.assigns.current_user, socket.assigns.subject)
  end

  defp authorize_socket_action(_socket) do
    :ok
  end

  @doc """
  This is called when modal is closed. Conveniently, allows us to reload devices table.
  """
  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:ok, devices} =
      Devices.list_devices_for_user(socket.assigns.current_user, socket.assigns.subject)

    socket =
      socket
      |> assign(:devices, devices)

    {:noreply, socket}
  end

  @doc """
  Render the "Install NexGuard Connect" card. Called in two places
  from the template (empty-state + collapsible under the device
  table); factored out here to keep both call sites reading the
  same thing.
  """
  def render_install_section(assigns) do
    ~H"""
    <div
      id="install-instructions"
      phx-hook="OSDetect"
      class="ng-detail-card"
    >
      <div class="ng-detail-card-header">
        <span class="ng-section-header">
          <i class="mdi mdi-download-outline"></i> Install NexGuard Connect
        </span>
      </div>
      <div class="ng-detail-card-body">
        <div class="ng-os-tabs" role="tablist" aria-label="Operating system">
          <%= for {os, label, icon} <- [
                {:macos, "macOS", "apple"},
                {:windows, "Windows", "microsoft-windows"},
                {:linux, "Linux", "linux"}
              ] do %>
            <button
              type="button"
              role="tab"
              class={["ng-os-tab", @install_selected_os == os && "is-active"]}
              aria-selected={to_string(@install_selected_os == os)}
              phx-click="select_install_os"
              phx-value-os={to_string(os)}
            >
              <i class={"mdi mdi-#{icon}"}></i>
              <span><%= label %></span>
            </button>
          <% end %>
        </div>

        <%# Static IDs so LiveView keeps the same DOM node across
        %# tab switches -- otherwise the InstallCopy hook remounts on
        %# every click and any pending "Copied ✓" revert timer runs
        %# against a detached node. %>
        <div class="ng-code-block">
          <pre><code id="install-cmd"><%= install_command(@install_selected_os) %></code></pre>
          <button
            id="install-copy-btn"
            type="button"
            class="ng-copy-btn"
            data-copy={install_command(@install_selected_os)}
            phx-hook="InstallCopy"
            aria-label="Copy install command"
          >
            <i class="mdi mdi-content-copy"></i>
            <span>Copy</span>
          </button>
        </div>

        <p class="ng-field-hint" style="margin-top:0.75rem">
          <%= install_hint(@install_selected_os) %>
        </p>
      </div>
    </div>
    """
  end
end
