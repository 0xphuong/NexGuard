defmodule FzHttp.EventsTest do
  @moduledoc """
  XXX: Use start_supervised! somehow here to allow async tests.
  """
  use FzHttp.DataCase, async: false
  import FzHttp.TestHelpers
  alias FzHttp.{UsersFixtures, DevicesFixtures}
  alias FzHttp.{Devices, Events}

  # XXX: Not needed with start_supervised!
  setup do
    on_exit(fn ->
      :sys.replace_state(Events.vpn_pid(), fn _state -> %{} end)

      :sys.replace_state(Events.wall_pid(), fn _state ->
        %{users: MapSet.new(), devices: MapSet.new(), rules: MapSet.new()}
      end)
    end)
  end

  describe "add_device/1" do
    test "adds device to wall and vpn state" do
      user = UsersFixtures.create_user_with_role(:admin)

      device =
        DevicesFixtures.create_device(
          user: user,
          name: "device"
        )

      :ok = Events.add("devices", device)

      assert :sys.get_state(Events.wall_pid()) ==
               %{
                 users: MapSet.new(),
                 devices:
                   MapSet.new([%{ip: "#{device.ipv4}", ip6: "#{device.ipv6}", user_id: user.id}]),
                 rules: MapSet.new()
               }

      assert :sys.get_state(Events.vpn_pid()) == %{
               device.public_key => %{
                 allowed_ips: "#{device.ipv4}/32,#{device.ipv6}/128",
                 preshared_key: device.preshared_key
               }
             }
    end
  end

  describe "delete_device/1" do
    setup [:create_user_and_device]

    test "removes device from vpn and wall state", %{device: device} do
      :ok = Events.add("devices", device)

      assert :ok = Events.delete("devices", device)

      assert :sys.get_state(Events.vpn_pid()) == %{}

      assert :sys.get_state(Events.wall_pid()) ==
               %{users: MapSet.new(), devices: MapSet.new(), rules: MapSet.new()}
    end
  end

  describe "create_user/1" do
    setup [:create_user_and_device]

    test "Adds user to wall state", %{user: user} do
      :ok = Events.add("users", user)

      assert :sys.get_state(Events.wall_pid()) ==
               %{users: MapSet.new([user.id]), devices: MapSet.new(), rules: MapSet.new()}
    end
  end

  describe "delete_user/1" do
    setup [:create_user_and_device]

    test "removes user from wall state", %{user: user} do
      :ok = Events.add("users", user)
      :ok = Events.delete("users", user)

      assert :sys.get_state(Events.wall_pid()) ==
               %{users: MapSet.new(), devices: MapSet.new(), rules: MapSet.new()}
    end
  end

  # NOTE: `add_rule/1`, `add_rule/1 accept`, `remove_rule/1`,
  # and `set_rules/0` describe blocks were removed in v4.0.0.
  # `Events.add("rules", ...)` / `Events.delete("rules", ...)`
  # no longer exist; policy-derived rules land via
  # `Events.set_rules/0` on Policies-context CRUD, which is
  # exercised via `test/fz_http/policies_test.exs`.

  describe "set_config/0" do
    setup [:create_devices]

    test "sets config" do
      :ok = Events.set_config()

      assert :sys.get_state(Events.vpn_pid()) ==
               Map.new(Devices.to_peer_list(), fn peer ->
                 {peer.public_key, %{allowed_ips: peer.inet, preshared_key: peer.preshared_key}}
               end)
    end
  end

  describe "vpn_pid/0" do
    test "uses the correct pid" do
      assert Events.vpn_pid() == :global.whereis_name(:fz_vpn_server)
    end
  end

  describe "wall_pid/0" do
    test "uses the correct pid" do
      assert Events.wall_pid() == :global.whereis_name(:fz_wall_server)
    end
  end
end
