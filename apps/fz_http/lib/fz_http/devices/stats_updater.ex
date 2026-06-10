defmodule FzHttp.Devices.StatsUpdater do
  @moduledoc """
  Extracts WireGuard data about each peer and adds it to
  the correspond device.
  """
  alias FzHttp.{AuditLogs, Devices, Devices.Device, Repo}
  require Logger

  # WireGuard renegotiates handshake every 180s.
  # A device is "connected" if its latest handshake is within this threshold.
  @connected_threshold_secs 180

  def update(stats) do
    for {public_key, data} <- stats do
      Device.Query.by_public_key(public_key)
      |> Repo.fetch()
      |> case do
        {:ok, device} ->
          new_handshake = latest_handshake(data.latest_handshake)
          new_remote_ip = parse_ip(data.endpoint)

          was_connected = connected?(device.latest_handshake)
          is_connected = connected?(new_handshake)

          Logger.debug("[VPN] #{device.name} was_connected=#{was_connected} is_connected=#{is_connected} old_hs=#{inspect(device.latest_handshake)} new_hs=#{inspect(new_handshake)}")

          attrs = %{
            rx_bytes: String.to_integer(data.rx_bytes),
            tx_bytes: String.to_integer(data.tx_bytes),
            remote_ip: new_remote_ip
          }

          # Skip latest_handshake when peer hasn't handshaken yet, so we don't
          # clobber the previous good value with 1970-01-01.
          attrs =
            if new_handshake do
              Map.put(attrs, :latest_handshake, new_handshake)
            else
              attrs
            end

          {resp, _} = Devices.update_metrics(device, attrs)

          maybe_log_vpn_event(was_connected, is_connected, device, new_remote_ip)

          resp

        {:error, :not_found} ->
          :ok
      end
    end
  end

  defp maybe_log_vpn_event(false, true, device, new_remote_ip) do
    device = Repo.preload(device, :user)

    AuditLogs.log("vpn.connect",
      actor_id: device.user_id,
      actor_email: device.user.email,
      ip_address: new_remote_ip,
      target_type: "device",
      target_id: device.id,
      target_label: device.name
    )
  end

  defp maybe_log_vpn_event(true, false, device, _new_remote_ip) do
    device = Repo.preload(device, :user)
    last_ip = device.remote_ip && to_string(device.remote_ip)

    AuditLogs.log("vpn.disconnect",
      actor_id: device.user_id,
      actor_email: device.user.email,
      ip_address: last_ip,
      target_type: "device",
      target_id: device.id,
      target_label: device.name
    )
  end

  defp maybe_log_vpn_event(_was, _is_now, _device, _new_remote_ip), do: :ok

  defp connected?(nil), do: false

  defp connected?(%DateTime{} = ts) do
    DateTime.diff(DateTime.utc_now(), ts) < @connected_threshold_secs
  end

  # WireGuard returns latest_handshake=0 for peers that have never completed a
  # handshake (e.g. right after a peer is freshly added). Treat that as "no
  # handshake yet" so the caller can skip the field instead of overwriting a
  # previously good timestamp with 1970-01-01.
  defp latest_handshake("0"), do: nil

  defp latest_handshake(epoch) do
    epoch
    |> String.to_integer()
    |> DateTime.from_unix!()
  end

  # Returns nil for "(none)" so remote_ip stays unchanged on devices that never connected.
  defp parse_ip("(none)"), do: nil

  defp parse_ip(endpoint) do
    endpoint
    |> String.replace(~r{:\d+$}, "")
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
  end

  def endpoint_to_ip(endpoint), do: parse_ip(endpoint)
end
