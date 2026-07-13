defmodule FzHttp.Devices.Device do
  use FzHttp, :schema

  schema "devices" do
    field(:name, :string)
    field(:description, :string)

    field(:public_key, :string)
    field(:preshared_key, FzHttp.Encrypted.Binary)

    field(:use_default_allowed_ips, :boolean, read_after_writes: true, default: true)
    field(:use_default_dns, :boolean, read_after_writes: true, default: true)
    field(:use_default_endpoint, :boolean, read_after_writes: true, default: true)
    field(:use_default_mtu, :boolean, read_after_writes: true, default: true)
    field(:use_default_persistent_keepalive, :boolean, read_after_writes: true, default: true)

    field(:endpoint, :string)
    field(:mtu, :integer)
    field(:persistent_keepalive, :integer)
    field(:allowed_ips, {:array, FzHttp.Types.INET}, default: [])
    field(:dns, {:array, :string}, default: [])

    field(:ipv4, FzHttp.Types.IP)
    field(:ipv6, FzHttp.Types.IP)

    field(:remote_ip, FzHttp.Types.IP)
    field(:rx_bytes, :integer)
    field(:tx_bytes, :integer)
    field(:latest_handshake, :utc_datetime_usec)

    # Admin approval workflow. New native enrollments default to "pending";
    # devices created via the portal default to "approved" (admin act = approval).
    field(:status, :string, default: "approved")
    field(:approved_at, :utc_datetime_usec)

    # Passive client metadata from X-NexGuard-Client-* headers on
    # enroll + config-fetch calls. `client_platform` + `client_version`
    # identify the native client build (macos/windows/linux-cli);
    # `client_os_*` + `client_arch` identify the host operating system
    # + CPU underneath. `client_last_seen_at` is our "when we last
    # heard from this client" timestamp -- distinct from updated_at
    # (any field change) or latest_handshake (only on WG traffic).
    field(:client_platform,   :string)
    field(:client_version,    :string)
    field(:client_os_name,    :string)
    field(:client_os_version, :string)
    field(:client_arch,       :string)
    field(:client_last_seen_at, :utc_datetime_usec)

    belongs_to(:user, FzHttp.Users.User)
    belongs_to(:approved_by, FzHttp.Users.User, foreign_key: :approved_by_id)

    timestamps()
  end
end
