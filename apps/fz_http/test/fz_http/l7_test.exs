defmodule FzHttp.L7Test do
  use FzHttp.DataCase, async: true

  alias FzHttp.DevicesFixtures
  alias FzHttp.L7
  alias FzHttp.UsersFixtures

  setup do
    :ok = L7.subscribe_identity()
    :ok
  end

  describe "broadcast_identity_change/1" do
    test "fans out one event per VPN IP (ipv4 + ipv6) on the user's devices" do
      user = UsersFixtures.create_user_with_role(:unprivileged)
      device = DevicesFixtures.create_device(user: user)

      :ok = L7.broadcast_identity_change(user)

      ipv4 = FzHttp.Types.INET.to_string(device.ipv4)
      ipv6 = FzHttp.Types.INET.to_string(device.ipv6)

      assert_receive {:identity_updated, ^ipv4}, 500
      assert_receive {:identity_updated, ^ipv6}, 500
    end

    test "emits two events when the user owns two devices" do
      user = UsersFixtures.create_user_with_role(:unprivileged)
      d1 = DevicesFixtures.create_device(user: user)
      d2 = DevicesFixtures.create_device(user: user)

      :ok = L7.broadcast_identity_change(user)

      for d <- [d1, d2] do
        ipv4 = FzHttp.Types.INET.to_string(d.ipv4)
        assert_receive {:identity_updated, ^ipv4}, 500
      end
    end

    test "silent no-op when the user has no devices" do
      user = UsersFixtures.create_user_with_role(:unprivileged)
      :ok = L7.broadcast_identity_change(user)

      refute_receive {:identity_updated, _}, 200
    end
  end

  describe "wiring from contexts" do
    test "AccessGroups.add_member/4 emits both :groups_changed and :identity_updated" do
      :ok = FzHttp.AccessGroups.subscribe_groups()

      user = UsersFixtures.create_user_with_role(:unprivileged)
      device = DevicesFixtures.create_device(user: user)
      group = FzHttp.AccessGroupsFixtures.create_group()
      subject = FzHttp.SubjectFixtures.create_subject()

      {:ok, _m} = FzHttp.AccessGroups.add_member(group, user, subject)

      assert_receive :groups_changed, 500

      ipv4 = FzHttp.Types.INET.to_string(device.ipv4)
      assert_receive {:identity_updated, ^ipv4}, 500
    end

    test "AccessGroups.create_group/3 emits :groups_changed but no identity event" do
      :ok = FzHttp.AccessGroups.subscribe_groups()

      subject = FzHttp.SubjectFixtures.create_subject()

      {:ok, _g} =
        FzHttp.AccessGroups.create_group(
          %{name: "g-#{System.unique_integer([:positive])}", description: "x"},
          subject
        )

      assert_receive :groups_changed, 500
      refute_receive {:identity_updated, _}, 200
    end

    test "Users.set_access_scope/4 emits :identity_updated when scope actually changes" do
      user = UsersFixtures.create_user_with_role(:unprivileged)
      device = DevicesFixtures.create_device(user: user)
      subject = FzHttp.SubjectFixtures.create_subject()

      {:ok, _u} = FzHttp.Users.set_access_scope(user, :all, subject)

      ipv4 = FzHttp.Types.INET.to_string(device.ipv4)
      assert_receive {:identity_updated, ^ipv4}, 500
    end

    test "Users.set_access_scope/4 is silent on no-op writes" do
      user = UsersFixtures.create_user_with_role(:unprivileged)
      _device = DevicesFixtures.create_device(user: user)
      subject = FzHttp.SubjectFixtures.create_subject()

      # user.access_scope already defaults to :limited
      {:ok, _u} = FzHttp.Users.set_access_scope(user, :limited, subject)

      refute_receive {:identity_updated, _}, 200
    end
  end
end
