defmodule FzHttpWeb.API.V1.DeviceController do
  @moduledoc """
  Native-client device endpoints. Authentication enforced by the
  `FzHttpWeb.Plug.NativeAuthBearer` plug (in the router pipeline).

  - `POST /api/v1/devices/enroll` — idempotent enroll. Body: `{name, public_key}`.
  - `GET  /api/v1/devices/me/config[?device_id=<uuid>]` — fetch the
    `wg-quick` config. `device_id` (added in v3.2.3) picks a specific
    row for multi-device users; omit for backward-compat "most-recent"
    lookup.
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
        device = record_client_info(conn, device)

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

  def me_config(conn, params) do
    user = conn.assigns.current_user
    device_id = Map.get(params, "device_id")

    case fetch_native_device(user, device_id) do
      {:ok, device} ->
        device = record_client_info(conn, device)
        json(conn, build_device_response(device))

      {:error, :not_found} ->
        send_error(conn, :not_found, "device_not_enrolled")

      {:error, :forbidden} ->
        send_error(conn, :forbidden, "device_not_owned")
    end
  end

  # ---- helpers ----

  # Stamp the device row with the platform + version reported by the
  # native client's request headers, plus a client_last_seen_at
  # timestamp. Best-effort: any DB error is logged + swallowed so a
  # telemetry write never breaks the enroll / config flow that
  # actually matters to the user.
  defp record_client_info(conn, device) do
    attrs = %{
      client_platform:   client_header(conn, "x-nexguard-client-platform"),
      client_version:    client_header(conn, "x-nexguard-client-version"),
      client_os_name:    client_header(conn, "x-nexguard-client-os-name"),
      client_os_version: client_header(conn, "x-nexguard-client-os-version"),
      client_arch:       client_header(conn, "x-nexguard-client-arch")
    }

    case Devices.record_client_info(device, attrs) do
      {:ok, updated}  -> updated
      {:error, error} ->
        Logger.warning("record_client_info failed: #{inspect(error)}")
        device
    end
  end

  # Extract a header value with client-supplied bounds. Missing header
  # OR literal "unknown" (client couldn't read its own version) both
  # collapse to nil so the DB column stays null instead of storing a
  # misleading "unknown" string.
  defp client_header(conn, name) do
    conn
    |> Plug.Conn.get_req_header(name)
    |> List.first()
    |> case do
      nil       -> nil
      ""        -> nil
      "unknown" -> nil
      value     -> String.slice(value, 0, 32)  # DB max_length is 32
    end
  end

  defp build_device_response(device) do
    %{
      device_id: device.id,
      device_name: device.name,
      status: device.status,
      wg_quick_config: WireguardConfigView.render("device.conf", device: device)
    }
  end

  # v3.2.3+ path: client sends the device_id it captured on enroll.
  # Fixes the "Windows A + Windows B collision" bug where a second
  # signed-in device hijacked the first's config (and vice versa)
  # because the fallback below picked the most-recent row for the
  # user regardless of who was actually asking. Delegates to the
  # Devices context so the not-found / forbidden semantics stay
  # consistent with the rest of the codebase.
  defp fetch_native_device(user, device_id) when is_binary(device_id) and device_id != "" do
    FzHttp.Devices.fetch_for_user_by_id(user, device_id)
  end

  # Backward-compat path: pre-v3.2.3 clients don't send device_id
  # (they were built against the old me_config that took no
  # parameters). Fall back to the most-recent device for this user.
  # Buggy for multi-device users -- recommend they upgrade to a
  # client build that sends device_id.
  defp fetch_native_device(user, _no_id) do
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
