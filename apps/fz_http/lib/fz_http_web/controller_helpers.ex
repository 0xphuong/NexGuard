defmodule FzHttpWeb.ControllerHelpers do
  @moduledoc """
  Useful helpers for controllers
  """
  use FzHttpWeb, :helper

  alias FzHttp.Users.User

  def root_path_for_user(nil) do
    ~p"/"
  end

  def root_path_for_user(%User{role: :admin}) do
    ~p"/dashboard"
  end

  def root_path_for_user(%User{role: :unprivileged}) do
    ~p"/user_devices"
  end

  @doc "Converts conn.remote_ip tuple to a printable string. Handles IPv4 and IPv6."
  def format_remote_ip(remote_ip) when is_tuple(remote_ip) do
    remote_ip |> :inet.ntoa() |> to_string()
  end

  def format_remote_ip(nil), do: nil

  @doc """
  Extracts the real client IP from a LiveView socket's connect_info.
  Uses X-Forwarded-For (respecting trusted proxies) when available,
  falling back to the direct peer address.
  """
  def extract_live_ip(socket) do
    x_headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []
    peer_data = Phoenix.LiveView.get_connect_info(socket, :peer_data)

    ip_tuple =
      RemoteIp.from(x_headers, FzHttpWeb.HeaderHelpers.remote_ip_opts()) ||
        (peer_data && peer_data.address)

    if ip_tuple, do: ip_tuple |> :inet.ntoa() |> to_string(), else: nil
  end
end
