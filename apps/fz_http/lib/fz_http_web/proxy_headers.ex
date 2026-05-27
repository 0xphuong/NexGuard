defmodule FzHttpWeb.ProxyHeaders do
  @moduledoc """
  Loads proxy-related headers when it corresponds using runtime config
  """
  alias FzHttpWeb.HeaderHelpers

  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    if HeaderHelpers.proxied?() do
      conn
      |> RemoteIp.call(RemoteIp.init(HeaderHelpers.remote_ip_opts()))
      |> Plug.RewriteOn.call(rewrite_opts())
    else
      conn
    end
  end

  defp rewrite_opts, do: Plug.RewriteOn.init([:x_forwarded_proto])
end
