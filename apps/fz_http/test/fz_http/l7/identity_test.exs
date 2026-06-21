defmodule FzHttp.L7.IdentityTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.AccessGroups
  alias FzHttp.AccessGroupsFixtures
  alias FzHttp.DevicesFixtures
  alias FzHttp.L7.Identity
  alias FzHttp.MFAFixtures
  alias FzHttp.SubjectFixtures
  alias FzHttp.UsersFixtures

  describe "lookup_by_vpn_ip/1" do
    test "resolves identity by IPv4" do
      user = UsersFixtures.create_user_with_role(:unprivileged)
      device = DevicesFixtures.create_device(user: user)

      ipv4 = FzHttp.Types.INET.to_string(device.ipv4)
      assert {:ok, identity, %{user_updated_at: _}} = Identity.lookup_by_vpn_ip(ipv4)

      assert identity.user_id == user.id
      assert identity.email == user.email
      assert identity.role == :unprivileged
      assert identity.access_scope == :limited
      assert identity.device_id == device.id
      assert identity.groups == []
    end

    test "resolves identity by IPv6" do
      user = UsersFixtures.create_user_with_role(:admin)
      device = DevicesFixtures.create_device(user: user)

      ipv6 = FzHttp.Types.INET.to_string(device.ipv6)
      assert {:ok, identity, _meta} = Identity.lookup_by_vpn_ip(ipv6)

      assert identity.user_id == user.id
      assert identity.role == :admin
    end

    test "returns :not_found for an unknown VPN IP" do
      assert :not_found = Identity.lookup_by_vpn_ip("100.64.99.99")
    end

    test "returns :not_found for an unparseable IP string" do
      assert :not_found = Identity.lookup_by_vpn_ip("not-an-ip")
      assert :not_found = Identity.lookup_by_vpn_ip("")
    end

    test "returns :not_found when the owning user is disabled (fail-closed)" do
      user = UsersFixtures.create_user_with_role(:unprivileged)
      device = DevicesFixtures.create_device(user: user)

      user
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Repo.update!()

      ipv4 = FzHttp.Types.INET.to_string(device.ipv4)
      assert :not_found = Identity.lookup_by_vpn_ip(ipv4)
    end

    test "includes group names" do
      user = UsersFixtures.create_user_with_role(:unprivileged)
      device = DevicesFixtures.create_device(user: user)
      group = AccessGroupsFixtures.create_group()
      admin_subject = SubjectFixtures.create_subject()
      {:ok, _} = AccessGroups.add_member(group, user, admin_subject)

      ipv4 = FzHttp.Types.INET.to_string(device.ipv4)
      assert {:ok, identity, _} = Identity.lookup_by_vpn_ip(ipv4)
      assert identity.groups == [group.name]
    end

    test "exposes user.updated_at in the cache meta" do
      user = UsersFixtures.create_user_with_role(:unprivileged)
      device = DevicesFixtures.create_device(user: user)

      ipv4 = FzHttp.Types.INET.to_string(device.ipv4)
      assert {:ok, _identity, %{user_updated_at: ts}} = Identity.lookup_by_vpn_ip(ipv4)
      assert %DateTime{} = ts
      assert DateTime.compare(ts, user.updated_at) == :eq
    end
  end

  describe "mfa_age_seconds" do
    test "is nil when the user has no MFA method (even if last_signed_in_at is set)" do
      user = UsersFixtures.create_user_with_role(:unprivileged)

      user
      |> Ecto.Changeset.change(last_signed_in_at: DateTime.utc_now())
      |> Repo.update!()

      device = DevicesFixtures.create_device(user: user)
      ipv4 = FzHttp.Types.INET.to_string(device.ipv4)

      assert {:ok, identity, _} = Identity.lookup_by_vpn_ip(ipv4)
      assert identity.mfa_age_seconds == nil
    end

    test "is nil when last_signed_in_at is nil" do
      user = UsersFixtures.create_user_with_role(:unprivileged)
      _method = MFAFixtures.create_totp_method(user: user)
      device = DevicesFixtures.create_device(user: user)

      ipv4 = FzHttp.Types.INET.to_string(device.ipv4)
      assert {:ok, identity, _} = Identity.lookup_by_vpn_ip(ipv4)
      assert identity.mfa_age_seconds == nil
    end

    test "reflects seconds since last_signed_in_at when MFA is configured" do
      user = UsersFixtures.create_user_with_role(:unprivileged)
      _method = MFAFixtures.create_totp_method(user: user)
      signed_in_at = DateTime.utc_now() |> DateTime.add(-120, :second)

      user
      |> Ecto.Changeset.change(last_signed_in_at: signed_in_at)
      |> Repo.update!()

      device = DevicesFixtures.create_device(user: user)
      ipv4 = FzHttp.Types.INET.to_string(device.ipv4)

      assert {:ok, identity, _} = Identity.lookup_by_vpn_ip(ipv4)
      assert identity.mfa_age_seconds >= 120
      assert identity.mfa_age_seconds < 130
    end
  end
end
