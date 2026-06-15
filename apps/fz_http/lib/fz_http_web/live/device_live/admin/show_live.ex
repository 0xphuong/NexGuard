defmodule FzHttpWeb.DeviceLive.Admin.Show do
  @moduledoc """
  Shows a device for an admin user.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.{Devices, Users}
  alias FzHttp.Devices.Device

  @impl Phoenix.LiveView
  def mount(%{"id" => device_id} = _params, _session, socket) do
    with {:ok, device} <- Devices.fetch_device_by_id(device_id, socket.assigns.subject) do
      {:ok, assign(socket, assigns(device))}
    else
      {:error, {:unauthorized, _context}} ->
        {:ok, not_authorized(socket)}

      {:error, :not_found} ->
        {:ok, not_authorized(socket)}
    end
  end

  @doc """
  Needed because this view will receive handle_params when modal is closed.
  """
  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("confirm_device_delete", _params, socket) do
    {:noreply, assign(socket, :show_device_confirm, true)}
  end

  def handle_event("cancel_device_delete", _params, socket) do
    {:noreply, assign(socket, :show_device_confirm, false)}
  end

  def handle_event("delete_device", _params, socket) do
    case Devices.delete_device(socket.assigns.device, socket.assigns.subject, socket.assigns.remote_ip) do
      {:ok, _deleted_device} ->
        {:noreply, redirect(socket, to: ~p"/devices")}

      {:error, {:unauthorized, _context}} ->
        {:noreply, not_authorized(socket)}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, "Error deleting device: #{msg}")}
    end
  end

  def handle_event("update_ip", %{"device" => attrs}, socket) do
    case Devices.admin_update_device(
           socket.assigns.device,
           attrs,
           socket.assigns.subject,
           socket.assigns.remote_ip
         ) do
      {:ok, updated} ->
        socket =
          socket
          |> assign(assigns(updated))
          |> assign(:ip_update_message,
            "IP updated. The device's client must sign out and sign in to apply the new configuration."
          )

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        socket =
          socket
          |> assign(:ip_changeset, changeset)
          |> assign(:ip_update_message, nil)

        {:noreply, socket}

      {:error, {:unauthorized, _context}} ->
        {:noreply, not_authorized(socket)}
    end
  end

  def handle_event("dismiss_ip_update_message", _params, socket) do
    {:noreply, assign(socket, :ip_update_message, nil)}
  end

  # ── Approve / Revoke confirmation modals ─────────────────────────────────

  def handle_event("confirm_approve_device", _params, socket) do
    {:noreply, assign(socket, :show_approve_confirm, true)}
  end

  def handle_event("cancel_approve_device", _params, socket) do
    {:noreply, assign(socket, :show_approve_confirm, false)}
  end

  def handle_event("confirm_revoke_approval", _params, socket) do
    {:noreply, assign(socket, :show_revoke_confirm, true)}
  end

  def handle_event("cancel_revoke_approval", _params, socket) do
    {:noreply, assign(socket, :show_revoke_confirm, false)}
  end

  def handle_event("approve_device", _params, socket) do
    case Devices.approve_device(
           socket.assigns.device,
           socket.assigns.subject,
           socket.assigns.remote_ip
         ) do
      {:ok, updated} ->
        socket =
          socket
          |> assign(assigns(updated))
          |> put_flash(:info, "Device approved. The user can now connect to the VPN.")

        {:noreply, socket}

      {:error, {:unauthorized, _context}} ->
        {:noreply, not_authorized(socket)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Approve failed: #{inspect(changeset.errors)}")}
    end
  end

  def handle_event("revoke_approval", _params, socket) do
    case Devices.revoke_approval(
           socket.assigns.device,
           socket.assigns.subject,
           socket.assigns.remote_ip
         ) do
      {:ok, updated} ->
        socket =
          socket
          |> assign(assigns(updated))
          |> put_flash(:info, "Approval revoked. The device is now pending and cannot connect.")

        {:noreply, socket}

      {:error, {:unauthorized, _context}} ->
        {:noreply, not_authorized(socket)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Revoke failed: #{inspect(changeset.errors)}")}
    end
  end

  defp assigns(device) do
    defaults = Devices.defaults()

    [
      device: device,
      user: Users.fetch_user_by_id!(device.user_id),
      page_title: device.name,
      show_device_confirm: false,
      ip_changeset: Device.Changeset.admin_update_changeset(device, %{}),
      ip_update_message: nil,
      show_approve_confirm: false,
      show_revoke_confirm: false,
      allowed_ips: Devices.get_allowed_ips(device, defaults),
      dns: Devices.get_dns(device, defaults),
      endpoint: Devices.get_endpoint(device, defaults),
      mtu: Devices.get_mtu(device, defaults),
      persistent_keepalive: Devices.get_persistent_keepalive(device, defaults),
      config: FzHttpWeb.WireguardConfigView.render("device.conf", %{device: device})
    ]
  end
end
