defmodule FzHttpWeb.API.V1.DeviceController do
  @moduledoc """
  Native-client device endpoints. Authentication enforced by the
  `FzHttpWeb.Plug.NativeAuthBearer` plug (in the router pipeline).

  - `POST /api/v1/devices/enroll` — idempotent enroll. Body: `{name, public_key}`.
  - `GET  /api/v1/devices/me/config` — fetch the latest `wg-quick` config for this device.
  """
  use FzHttpWeb, :controller
  require Logger

  alias FzHttp.{AuditLogs, Devices}
  alias FzHttpWeb.WireguardConfigView

  def enroll(conn, %{"name" => name, "public_key" => public_key})
      when is_binary(name) and is_binary(public_key) do
    user = conn.assigns.current_user

    case Devices.find_or_create_for_user(user, name, public_key) do
      {:ok, device} ->
        AuditLogs.log("device.create",
          actor_id: user.id,
          actor_email: user.email,
          ip_address: format_remote_ip(conn.remote_ip),
          target_type: "device",
          target_id: device.id,
          target_label: device.name,
          metadata: %{source: "native_enroll"}
        )

        json(conn, build_device_response(device))

      {:error, %Ecto.Changeset{} = cs} ->
        Logger.warning("native enroll failed: #{inspect(cs.errors)}")
        send_error(conn, :bad_request, format_errors(cs))
    end
  end

  def enroll(conn, _params), do: send_error(conn, :bad_request, "missing_params")

  def me_config(conn, _params) do
    user = conn.assigns.current_user

    case fetch_native_device(user) do
      {:ok, device} ->
        json(conn, build_device_response(device))

      {:error, :not_found} ->
        send_error(conn, :not_found, "device_not_enrolled")
    end
  end

  # ---- helpers ----

  defp build_device_response(device) do
    %{
      device_id: device.id,
      device_name: device.name,
      status: device.status,
      wg_quick_config: WireguardConfigView.render("device.conf", device: device)
    }
  end

  # Heuristic: most recent device for this user (single-machine clients
  # only enroll one device; the recent-first ordering picks the right row
  # if name ever changes between enrolls).
  defp fetch_native_device(user) do
    import Ecto.Query
    alias FzHttp.{Repo, Devices.Device}

    Device
    |> where([d], d.user_id == ^user.id)
    |> order_by([d], desc: d.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      device -> {:ok, device}
    end
  end

  defp send_error(conn, status, msg) do
    conn |> put_status(status) |> json(%{error: msg})
  end

  defp format_errors(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map_join(", ", fn {field, {msg, _opts}} -> "#{field} #{msg}" end)
  end
end
