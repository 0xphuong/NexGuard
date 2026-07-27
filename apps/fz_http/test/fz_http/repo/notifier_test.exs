defmodule FzHttp.Repo.NotifierTest do
  use FzHttp.DataCase, async: false
  import FzHttp.TestHelpers
  alias FzHttp.Repo.Notifier
  alias FzHttp.Events

  setup do
    on_exit(fn ->
      :sys.replace_state(Events.vpn_pid(), fn _state -> %{} end)

      :sys.replace_state(Events.wall_pid(), fn _state ->
        %{users: MapSet.new(), devices: MapSet.new(), rules: MapSet.new()}
      end)
    end)
  end

  describe "users changed" do
    setup :create_user

    test "adds user to wall state", %{user: user} do
      Notifier.handle_event("users", %{op: "INSERT", row: user})

      expected_state = %{
        users: MapSet.new([user.id]),
        rules: MapSet.new([]),
        devices: MapSet.new([])
      }

      assert :sys.get_state(Events.wall_pid()) == expected_state
    end

    test "user delete removes user from wall state", %{user: user} do
      Notifier.handle_event("users", %{op: "INSERT", row: user})
      Notifier.handle_event("users", %{op: "DELETE", row: user})

      expected_state = %{
        users: MapSet.new([]),
        rules: MapSet.new([]),
        devices: MapSet.new([])
      }

      assert :sys.get_state(Events.wall_pid()) == expected_state
    end
  end

  # NOTE: "rules changed" LISTEN/NOTIFY plumbing was removed in
  # v4.0.0 along with the legacy `rules` table. Policy CRUD
  # triggers `FzHttp.Events.set_rules/0` directly rather than
  # via Postgres NOTIFY; there is no equivalent Notifier event
  # channel for `policies` / `policy_rules`.

  describe "devices changed" do
    setup :create_user_and_device

    test "device insert adds device to vpn and wall state", %{device: device, user: user} do
      Notifier.handle_event("devices", %{op: "INSERT", row: device})

      expected_vpn_state = %{
        device.public_key => %{
          allowed_ips: "#{device.ipv4}/32,#{device.ipv6}/128",
          preshared_key: device.preshared_key
        }
      }

      expected_wall_state = %{
        users: MapSet.new([]),
        rules: MapSet.new([]),
        devices: MapSet.new([%{ip: "#{device.ipv4}", ip6: "#{device.ipv6}", user_id: user.id}])
      }

      assert :sys.get_state(Events.vpn_pid()) == expected_vpn_state
      assert :sys.get_state(Events.wall_pid()) == expected_wall_state
    end

    test "device delete removes device from vpn and wall state", %{device: device} do
      Notifier.handle_event("devices", %{op: "INSERT", row: device})
      Notifier.handle_event("devices", %{op: "DELETE", row: device})

      expected_vpn_state = %{}

      expected_wall_state = %{
        users: MapSet.new([]),
        rules: MapSet.new([]),
        devices: MapSet.new([])
      }

      assert :sys.get_state(Events.vpn_pid()) == expected_vpn_state
      assert :sys.get_state(Events.wall_pid()) == expected_wall_state
    end
  end
end
