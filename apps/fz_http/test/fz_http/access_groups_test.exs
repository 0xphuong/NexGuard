defmodule FzHttp.AccessGroupsTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.AccessGroups
  alias FzHttp.AccessGroups.{Group, Membership}
  alias FzHttp.{AccessGroupsFixtures, SubjectFixtures, UsersFixtures}

  setup do
    admin = UsersFixtures.create_user_with_role(:admin)
    unpriv = UsersFixtures.create_user_with_role(:unprivileged)

    %{
      admin: admin,
      admin_subject: SubjectFixtures.create_subject(admin),
      unpriv: unpriv,
      unpriv_subject: SubjectFixtures.create_subject(unpriv)
    }
  end

  describe "list_groups/1" do
    test "admin sees all groups with member counts", %{admin_subject: subject, admin: admin} do
      g1 = AccessGroupsFixtures.create_group(%{name: "eng-test"})
      _g2 = AccessGroupsFixtures.create_group(%{name: "ops-test"})
      {:ok, _} = AccessGroups.add_member(g1, admin, subject)

      {:ok, groups} = AccessGroups.list_groups(subject)

      assert length(groups) >= 2
      g1_returned = Enum.find(groups, &(&1.name == "eng-test"))
      g2_returned = Enum.find(groups, &(&1.name == "ops-test"))

      assert g1_returned.member_count == 1
      assert g2_returned.member_count == 0
    end

    test "unprivileged user gets empty list (defense-in-depth)", %{unpriv_subject: subject} do
      AccessGroupsFixtures.create_group()
      assert {:error, _} = AccessGroups.list_groups(subject)
    end
  end

  describe "create_group/3" do
    test "admin creates a group and gets it back with default source",
         %{admin_subject: subject} do
      assert {:ok, group} =
               AccessGroups.create_group(%{name: "verify-create"}, subject)

      assert group.name == "verify-create"
      assert group.source == :manual
      assert group.id
    end

    test "rejects duplicate name", %{admin_subject: subject} do
      AccessGroupsFixtures.create_group(%{name: "dup-name"})

      assert {:error, cs} = AccessGroups.create_group(%{name: "dup-name"}, subject)
      assert "has already been taken" in errors_on(cs).name
    end

    test "rejects name with invalid characters", %{admin_subject: subject} do
      assert {:error, cs} = AccessGroups.create_group(%{name: "bad@name!"}, subject)
      assert errors_on(cs).name != []
    end

    test "rejects too-short name", %{admin_subject: subject} do
      assert {:error, cs} = AccessGroups.create_group(%{name: "x"}, subject)
      assert errors_on(cs).name != []
    end

    test "rejects source = idp_sync via manual creation", %{admin_subject: subject} do
      assert {:error, cs} =
               AccessGroups.create_group(
                 %{name: "spoofed-idp", source: :idp_sync},
                 subject
               )

      assert errors_on(cs).source != []
    end

    test "unprivileged user cannot create", %{unpriv_subject: subject} do
      assert {:error, _} = AccessGroups.create_group(%{name: "nope"}, subject)
    end
  end

  describe "update_group/4" do
    test "admin can rename + redescribe", %{admin_subject: subject} do
      group = AccessGroupsFixtures.create_group(%{name: "before-update"})

      assert {:ok, updated} =
               AccessGroups.update_group(group, %{name: "after-update", description: "new"}, subject)

      assert updated.name == "after-update"
      assert updated.description == "new"
    end

    test "update_changeset ignores source field (immutable)", %{admin_subject: subject} do
      group = AccessGroupsFixtures.create_group(%{name: "immutable-source"})

      assert {:ok, updated} =
               AccessGroups.update_group(group, %{source: :idp_sync}, subject)

      assert updated.source == :manual
    end
  end

  describe "delete_group/3" do
    test "deletes and cascades memberships", %{admin: admin, admin_subject: subject} do
      group = AccessGroupsFixtures.create_group()
      {:ok, _} = AccessGroups.add_member(group, admin, subject)

      assert Repo.aggregate(Membership, :count) >= 1

      assert {:ok, _deleted} = AccessGroups.delete_group(group, subject)

      assert Repo.get(Group, group.id) == nil
      assert Repo.get_by(Membership, user_id: admin.id, group_id: group.id) == nil
    end
  end

  describe "add_member/4 + remove_member/4" do
    test "round-trip a single membership", %{admin: admin, admin_subject: subject} do
      group = AccessGroupsFixtures.create_group()

      assert {:ok, %Membership{} = m} = AccessGroups.add_member(group, admin, subject)
      assert m.user_id == admin.id
      assert m.group_id == group.id
      assert m.source == :manual
      assert m.added_by_id == admin.id

      assert {:ok, :removed} = AccessGroups.remove_member(group, admin, subject)
      assert Repo.get_by(Membership, user_id: admin.id, group_id: group.id) == nil
    end

    test "rejects duplicate membership", %{admin: admin, admin_subject: subject} do
      group = AccessGroupsFixtures.create_group()
      {:ok, _} = AccessGroups.add_member(group, admin, subject)

      assert {:error, cs} = AccessGroups.add_member(group, admin, subject)
      assert errors_on(cs)[:user_id] != nil or errors_on(cs)[:group_id] != nil
    end

    test "remove_member on a non-member returns :not_found",
         %{admin: admin, admin_subject: subject} do
      group = AccessGroupsFixtures.create_group()
      assert {:error, :not_found} = AccessGroups.remove_member(group, admin, subject)
    end
  end

  describe "list_groups_for_user/1 (identity API)" do
    test "returns only groups the user belongs to" do
      admin = UsersFixtures.create_user_with_role(:admin)
      other = UsersFixtures.create_user_with_role(:admin)
      subject = SubjectFixtures.create_subject(admin)

      g_in     = AccessGroupsFixtures.create_group(%{name: "in-group"})
      _g_other = AccessGroupsFixtures.create_group(%{name: "other-group"})

      {:ok, _} = AccessGroups.add_member(g_in, admin, subject)
      # other user isn't in any group

      assert [g] = AccessGroups.list_groups_for_user(admin)
      assert g.id == g_in.id

      assert AccessGroups.list_groups_for_user(other) == []
    end
  end
end
