defmodule FzHttp.Devices do
  alias FzHttp.{Repo, Config, Auth, Validator, AuditLogs}
  alias FzHttp.{Users, Telemetry}
  alias FzHttp.Devices.{Device, Authorizer}

  def count do
    Device.Query.all()
    |> Repo.aggregate(:count)
  end

  # True when the device has at least one real WireGuard handshake. Treats
  # epoch-zero timestamps (1970-01-01) as "never" — they can appear in legacy
  # rows where stats_updater overwrote a good value with `DateTime.from_unix!(0)`
  # before the bug fix landed.
  def has_handshaken?(%Device{latest_handshake: nil}), do: false
  def has_handshaken?(%Device{latest_handshake: %DateTime{year: year}}) when year < 2000, do: false
  def has_handshaken?(%Device{latest_handshake: %DateTime{}}), do: true

  # ── Connection state ────────────────────────────────────────────
  #
  # Answers "is this device healthy right now?" — used by /devices,
  # /users/:id/devices, and the device show pages to merge what used
  # to be two separate columns (admin status + raw handshake ts).
  # `:pending` overrides everything: an unapproved device can never
  # be "connected" because the proxy peer list excludes it.

  @connected_threshold_seconds 180
  @recent_threshold_seconds 86_400
  @idle_threshold_seconds 30 * 86_400

  def connection_state(%Device{status: "pending"}), do: :pending

  def connection_state(%Device{} = device) do
    if has_handshaken?(device) do
      diff = DateTime.diff(DateTime.utc_now(), device.latest_handshake, :second)

      cond do
        diff <= @connected_threshold_seconds -> :connected
        diff <= @recent_threshold_seconds    -> :recent
        diff <= @idle_threshold_seconds      -> :idle
        true                                 -> :stale
      end
    else
      :never
    end
  end

  def connection_class(:connected), do: "ng-conn--connected"
  def connection_class(:recent),    do: "ng-conn--recent"
  def connection_class(:idle),      do: "ng-conn--idle"
  def connection_class(:stale),     do: "ng-conn--stale"
  def connection_class(:pending),   do: "ng-conn--pending"
  def connection_class(:never),     do: "ng-conn--never"

  def connection_label(:connected), do: "Connected"
  def connection_label(:recent),    do: "Recent"
  def connection_label(:idle),      do: "Idle"
  def connection_label(:stale),     do: "Stale"
  def connection_label(:pending),   do: "Pending"
  def connection_label(:never),     do: "Never connected"

  def connection_icon(:connected), do: "mdi-circle"
  def connection_icon(:recent),    do: "mdi-circle-outline"
  def connection_icon(:idle),      do: "mdi-circle-outline"
  def connection_icon(:stale),     do: "mdi-alert-circle-outline"
  def connection_icon(:pending),   do: "mdi-clock-outline"
  def connection_icon(:never),     do: "mdi-minus-circle-outline"

  def relative_handshake(nil), do: nil
  def relative_handshake(%DateTime{year: y}) when y < 2000, do: nil

  def relative_handshake(%DateTime{} = ts) do
    diff = DateTime.diff(DateTime.utc_now(), ts, :second)

    cond do
      diff < 60      -> "just now"
      diff < 3600    -> "#{div(diff, 60)}m ago"
      diff < 86_400  -> "#{div(diff, 3600)}h ago"
      true           -> "#{div(diff, 86_400)}d ago"
    end
  end

  def count_by_user_id(user_id) do
    Device.Query.by_user_id(user_id)
    |> Repo.aggregate(:count)
  end

  def count_active_within(duration_in_seconds) when is_integer(duration_in_seconds) do
    Device.Query.by_latest_handshake_seconds_ago(duration_in_seconds)
    |> Repo.aggregate(:count)
  end

  def count_maximum_for_a_user do
    Device.Query.group_by_user_id()
    |> Device.Query.select_max_count()
    |> Repo.one()
  end

  def fetch_device_by_id(id, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_devices_permission(),
         Authorizer.view_own_devices_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Validator.valid_uuid?(id) do
      Device.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_device_by_id!(id) do
    Device.Query.by_id(id)
    |> Repo.one!()
  end

  def list_devices(%Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_devices_permission(),
         Authorizer.view_own_devices_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      Device.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    end
  end

  def list_devices_for_user(%Users.User{} = user, %Auth.Subject{} = subject) do
    list_devices_by_user_id(user.id, subject)
  end

  def list_devices_by_user_id(user_id, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_devices_permission(),
         Authorizer.view_own_devices_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      Device.Query.by_user_id(user_id)
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    end
  end

  def new_device(attrs \\ %{}) do
    Device.Changeset.create_changeset(attrs)
    |> Device.Changeset.configure_changeset(attrs)
  end

  def change_device(%Device{} = device, attrs \\ %{}) do
    Device.Changeset.update_changeset(device, attrs)
    |> Device.Changeset.configure_changeset(attrs)
  end

  def create_device_for_user(%Users.User{} = user, attrs \\ %{}, %Auth.Subject{} = subject, ip_address \\ nil) do
    with :ok <- authorize_user_device_management(user.id, subject) do
      changeset = Device.Changeset.create_changeset(user, attrs)

      changeset =
        if authorize_device_configuration(subject) == :ok do
          Device.Changeset.configure_changeset(changeset, attrs)
        else
          changeset
        end

      case Repo.insert(changeset) do
        {:ok, device} ->
          Telemetry.add_device()

          case subject.actor do
            {:user, actor} ->
              AuditLogs.log("device.create",
                actor_id: actor.id,
                actor_email: actor.email,
                ip_address: ip_address,
                target_type: "device",
                target_id: device.id,
                target_label: device.name,
                metadata: %{user_id: device.user_id}
              )

            _ ->
              :ok
          end

          {:ok, device}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def authorize_device_configuration(subject) do
    Auth.ensure_has_permissions(subject, Authorizer.configure_devices_permission())
  end

  def authorize_user_device_management(%Users.User{} = user, %Auth.Subject{} = subject) do
    authorize_user_device_management(user.id, subject)
  end

  def authorize_user_device_management(user_id, %Auth.Subject{} = subject) do
    required_permissions =
      case subject.actor do
        {:user, %{id: ^user_id}} ->
          Authorizer.manage_own_devices_permission()

        _other ->
          Authorizer.manage_devices_permission()
      end

    Auth.ensure_has_permissions(subject, required_permissions)
  end

  def update_device(%Device{} = device, attrs, %Auth.Subject{} = subject) do
    with :ok <- authorize_user_device_management(device.user_id, subject) do
      device
      |> Device.Changeset.update_changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Admin-only update that may change tunnel IPs in addition to name/description.
  Triggers a WG peer-list re-sync via `Events.set_config/0` so the new IP is
  applied to the running interface immediately. Clients still need to sign
  out + sign in to pick up the new config locally.
  """
  def admin_update_device(%Device{} = device, attrs, %Auth.Subject{} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_devices_permission()),
         changeset <- Device.Changeset.admin_update_changeset(device, attrs),
         {:ok, updated} <- Repo.update(changeset) do
      # Re-sync WG peer list with new IPs so server-side routing is correct.
      FzHttp.Events.set_config()

      # Audit only when IPs actually changed (skip noise on name/description edits).
      if to_string(device.ipv4) != to_string(updated.ipv4) or
           to_string(device.ipv6) != to_string(updated.ipv6) do
        case subject.actor do
          {:user, actor} ->
            AuditLogs.log("device.ip.change",
              actor_id: actor.id,
              actor_email: actor.email,
              ip_address: ip_address,
              target_type: "device",
              target_id: updated.id,
              target_label: updated.name,
              metadata: %{
                old_ipv4: to_string(device.ipv4),
                new_ipv4: to_string(updated.ipv4),
                old_ipv6: to_string(device.ipv6),
                new_ipv6: to_string(updated.ipv6)
              }
            )

          _ ->
            :ok
        end
      end

      {:ok, updated}
    end
  end

  def update_metrics(%Device{} = device, attrs) do
    device
    |> Device.Changeset.metrics_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Record client + OS telemetry + last-seen from the native client's
  request headers. Passive, no auth check needed -- the caller already
  authenticated the request as this device's user via `NativeAuthBearer`.

  `attrs` is a map that may contain any subset of:
      :client_platform    "macos" | "windows" | "linux-cli"
      :client_version     "0.3.1"
      :client_os_name     "macOS" | "Windows Server 2022 Datacenter" | "Ubuntu"
      :client_os_version  "14.3.1" | "10.0.20348" | "22.04.3 LTS"
      :client_arch        "arm64" | "x86_64" | "aarch64"

  Any value may be `nil` (client couldn't read it, or a rogue proxy
  stripped the header) -- we still stamp `client_last_seen_at` so
  admins can spot devices where telemetry never comes through.

  Errors are swallowed on purpose (best-effort). A telemetry write must
  never break the actual enroll / config flow.
  """
  def record_client_info(%Device{} = device, attrs) when is_map(attrs) do
    permitted = [
      :client_platform, :client_version,
      :client_os_name, :client_os_version, :client_arch,
      :client_last_seen_at
    ]

    attrs_with_seen = Map.put(attrs, :client_last_seen_at, DateTime.utc_now())

    device
    |> Ecto.Changeset.cast(attrs_with_seen, permitted)
    |> Ecto.Changeset.validate_length(:client_platform,   max: 32)
    |> Ecto.Changeset.validate_length(:client_version,    max: 32)
    |> Ecto.Changeset.validate_length(:client_os_name,    max: 64)
    |> Ecto.Changeset.validate_length(:client_os_version, max: 32)
    |> Ecto.Changeset.validate_length(:client_arch,       max: 16)
    |> Repo.update()
  end

  def delete_device(%Device{} = device, %Auth.Subject{} = subject, ip_address \\ nil) do
    with :ok <- authorize_user_device_management(device.user_id, subject),
         {:ok, deleted_device} <- Repo.delete(device) do
      Telemetry.delete_device()
      FzHttp.Notifications.clear_for_device(deleted_device.id)

      case subject.actor do
        {:user, actor} ->
          AuditLogs.log("device.delete",
            actor_id: actor.id,
            actor_email: actor.email,
            ip_address: ip_address,
            target_type: "device",
            target_id: device.id,
            target_label: device.name,
            metadata: %{user_id: device.user_id}
          )

        _ ->
          :ok
      end

      {:ok, deleted_device}
    end
  end

  def generate_name(name \\ FzHttp.NameGenerator.generate()) do
    hash =
      name
      |> :erlang.phash2(2 ** 16)
      |> Integer.to_string(16)
      |> String.pad_leading(4, "0")

    if String.length(name) > 15 do
      String.slice(name, 0..10) <> hash
    else
      name
    end
  end

  def setting_projection(device_or_map) do
    %{
      ip: if(device_or_map.ipv4, do: to_string(device_or_map.ipv4)),
      ip6: if(device_or_map.ipv6, do: to_string(device_or_map.ipv6)),
      user_id: device_or_map.user_id
    }
  end

  def as_settings do
    Device.Query.all()
    |> Repo.all()
    |> Enum.map(&setting_projection/1)
    |> MapSet.new()
  end

  def to_peer_list do
    Device.Query.all()
    |> Device.Query.only_active()
    |> Repo.all()
    |> Enum.map(fn device ->
      %{
        public_key: device.public_key,
        inet: inet(device),
        preshared_key: device.preshared_key
      }
    end)
  end

  def inet(device) do
    ips =
      if Config.fetch_env!(:fz_http, :wireguard_ipv6_enabled) == true do
        ["#{device.ipv6}/128"]
      else
        []
      end

    ips =
      if Config.fetch_env!(:fz_http, :wireguard_ipv4_enabled) == true do
        ["#{device.ipv4}/32"] ++ ips
      else
        ips
      end

    Enum.join(ips, ",")
  end

  def get_allowed_ips(device, defaults \\ defaults()), do: config(device, defaults, :allowed_ips)
  def get_endpoint(device, defaults \\ defaults()), do: config(device, defaults, :endpoint)

  @doc """
  DNS server list for a device's generated `.conf`.

  When L7 enforcement is enabled, the device MUST resolve declared
  application hostnames against the gateway's CoreDNS (which
  answers per-app VIPs). We override the admin-configured value
  with the WireGuard gateway IP regardless of `default_client_dns`
  so device configs always serve the right resolver — clients
  pointed at upstream DNS would get NXDOMAIN for every app
  hostname.

  When L7 is off, fall back to the admin's configured default
  (env override or DB value, whichever is in effect).
  """
  def get_dns(device, defaults \\ defaults()) do
    if FzHttp.OrgSettings.l7_enabled?() do
      [gateway_dns_ip()]
    else
      config(device, defaults, :dns)
    end
  end

  @doc """
  Gateway's WireGuard-side IPv4 — where CoreDNS listens for VPN
  clients. Exposed so the /settings/client_defaults UI can name
  the address admin can't override while L7 is on.
  """
  def gateway_dns_ip do
    FzHttp.Config.fetch_env!(:fz_http, :wireguard_ipv4_address)
    |> FzHttp.Types.IP.cast()
    |> case do
      {:ok, inet} -> FzHttp.Types.INET.to_string(inet)
      _ -> ""
    end
  end

  def get_mtu(device, defaults \\ defaults()), do: config(device, defaults, :mtu)

  def get_persistent_keepalive(device, defaults \\ defaults()),
    do: config(device, defaults, :persistent_keepalive)

  defp config(device, defaults, key) do
    if Map.get(device, String.to_atom("use_default_#{key}")) == true do
      Map.fetch!(defaults, String.to_atom("default_client_#{key}"))
    else
      Map.get(device, key)
    end
  end

  def defaults do
    Config.fetch_configs!([
      :default_client_allowed_ips,
      :default_client_endpoint,
      :default_client_dns,
      :default_client_mtu,
      :default_client_persistent_keepalive
    ])
  end

  @doc """
  Idempotent enroll for native clients. Lookup `(user_id, name)`:
    - not found       → create new device + sync VPN/firewall
    - found, same key → return existing (no-op)
    - found, new key  → update public_key (app re-installed) + resync VPN

  Returns `{:ok, device}` or `{:error, changeset}`.
  """
  def find_or_create_for_user(%Users.User{} = user, name, public_key)
      when is_binary(name) and is_binary(public_key) do
    case Repo.get_by(Device, user_id: user.id, name: name) do
      nil ->
        # New native-client enrollment requires admin approval. Existing
        # devices created via the admin portal keep the schema default of
        # "approved" since the admin creating them IS the approval.
        attrs = %{name: name, public_key: public_key, status: "pending"}

        changeset =
          Device.Changeset.create_changeset(user, attrs)
          |> Device.Changeset.configure_changeset(%{})
          |> Ecto.Changeset.put_change(:status, "pending")

        with {:ok, device} <- Repo.insert(changeset) do
          Telemetry.add_device()
          # Pending devices intentionally NOT pushed to the WG peer list yet —
          # Events.set_config + only_active filter handles this — but call it
          # anyway in case a stale entry exists for the same public_key.
          FzHttp.Events.add("devices", device)

          # Tell admins about it. The Notifications GenServer broadcasts via
          # PubSub so the navbar badge + Notifications page update in real
          # time without a refresh. `device_id` lets approve / revoke clear
          # this entry automatically.
          FzHttp.Notifications.add(%{
            type: :warning,
            device_id: device.id,
            message:
              "Device \"#{device.name}\" is pending approval. Approve it in Devices.",
            timestamp: DateTime.utc_now(),
            user: user.email
          })

          {:ok, device}
        end

      %Device{public_key: ^public_key} = device ->
        {:ok, device}

      %Device{} = device ->
        changeset =
          device
          |> Ecto.Changeset.cast(%{public_key: public_key}, [:public_key])
          |> Ecto.Changeset.validate_required([:public_key])
          |> Ecto.Changeset.validate_length(:public_key, is: 44)
          |> Ecto.Changeset.unique_constraint(:public_key)

        with {:ok, updated} <- Repo.update(changeset) do
          FzHttp.Events.set_config()
          {:ok, updated}
        end
    end
  end

  @doc """
  Approve a pending device. Admin-only. Sets `status="approved"`, stamps the
  approver, and triggers a WG peer-list resync so the device shows up in the
  kernel interface immediately. No-op (returns `{:ok, device}`) if already
  approved.
  """
  @doc """
  Bulk variants — apply `approve_device/3` / `revoke_approval/3` /
  `delete_device/3` over a list of ids. Each row goes through the
  same per-row guard + audit + PubSub broadcast as the single-row
  function, so the audit trail remains row-level (no opaque "bulk"
  rows) and a partial failure doesn't lose info.

  Returns a tally map: `%{ok: count, skip: count, error: count}`.
  `skip` covers no-op cases (approving an already-approved device,
  revoking an already-pending device); not an error.
  """
  def bulk_approve(ids, %Auth.Subject{} = subject, ip_address \\ nil) when is_list(ids) do
    Enum.reduce(ids, %{ok: 0, skip: 0, error: 0}, fn id, acc ->
      case Repo.get(Device, id) do
        nil ->
          %{acc | error: acc.error + 1}

        %Device{status: "approved"} ->
          %{acc | skip: acc.skip + 1}

        %Device{} = device ->
          case approve_device(device, subject, ip_address) do
            {:ok, _}    -> %{acc | ok: acc.ok + 1}
            _           -> %{acc | error: acc.error + 1}
          end
      end
    end)
  end

  def bulk_revoke_approval(ids, %Auth.Subject{} = subject, ip_address \\ nil)
      when is_list(ids) do
    Enum.reduce(ids, %{ok: 0, skip: 0, error: 0}, fn id, acc ->
      case Repo.get(Device, id) do
        nil ->
          %{acc | error: acc.error + 1}

        %Device{status: "pending"} ->
          %{acc | skip: acc.skip + 1}

        %Device{} = device ->
          case revoke_approval(device, subject, ip_address) do
            {:ok, _}    -> %{acc | ok: acc.ok + 1}
            _           -> %{acc | error: acc.error + 1}
          end
      end
    end)
  end

  def bulk_delete(ids, %Auth.Subject{} = subject, ip_address \\ nil) when is_list(ids) do
    Enum.reduce(ids, %{ok: 0, skip: 0, error: 0}, fn id, acc ->
      case Repo.get(Device, id) do
        nil ->
          %{acc | error: acc.error + 1}

        %Device{} = device ->
          case delete_device(device, subject, ip_address) do
            {:ok, _}    -> %{acc | ok: acc.ok + 1}
            _           -> %{acc | error: acc.error + 1}
          end
      end
    end)
  end

  def approve_device(%Device{} = device, %Auth.Subject{} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_devices_permission()) do
      if device.status == "approved" do
        {:ok, device}
      else
        actor_id =
          case subject.actor do
            {:user, %Users.User{id: id}} -> id
            _ -> nil
          end

        changeset =
          device
          |> Ecto.Changeset.change(%{
            status: "approved",
            approved_at: DateTime.utc_now(),
            approved_by_id: actor_id
          })

        with {:ok, updated} <- Repo.update(changeset) do
          FzHttp.Events.set_config()
          FzHttp.Notifications.clear_for_device(updated.id)

          case subject.actor do
            {:user, actor} ->
              AuditLogs.log("device.approve",
                actor_id: actor.id,
                actor_email: actor.email,
                ip_address: ip_address,
                target_type: "device",
                target_id: updated.id,
                target_label: updated.name,
                metadata: %{user_id: updated.user_id}
              )

            _ ->
              :ok
          end

          {:ok, updated}
        end
      end
    end
  end

  @doc """
  Revoke approval of an already-approved device. Admin-only. Sets back to
  `"pending"` and removes the device from the active WG peer list. Useful as
  a safety net when an admin mistakenly approves a device.
  """
  def revoke_approval(%Device{} = device, %Auth.Subject{} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_devices_permission()) do
      if device.status == "pending" do
        {:ok, device}
      else
        changeset =
          device
          |> Ecto.Changeset.change(%{
            status: "pending",
            approved_at: nil,
            approved_by_id: nil
          })

        with {:ok, updated} <- Repo.update(changeset) do
          FzHttp.Events.set_config()

          # Re-arm pending-approval notification — device is back to pending.
          user = FzHttp.Users.fetch_user_by_id!(updated.user_id)
          FzHttp.Notifications.add(%{
            type: :warning,
            device_id: updated.id,
            message:
              "Device \"#{updated.name}\" was revoked and is back to pending approval.",
            timestamp: DateTime.utc_now(),
            user: user.email
          })

          case subject.actor do
            {:user, actor} ->
              AuditLogs.log("device.revoke_approval",
                actor_id: actor.id,
                actor_email: actor.email,
                ip_address: ip_address,
                target_type: "device",
                target_id: updated.id,
                target_label: updated.name,
                metadata: %{user_id: updated.user_id}
              )

            _ ->
              :ok
          end

          {:ok, updated}
        end
      end
    end
  end
end
