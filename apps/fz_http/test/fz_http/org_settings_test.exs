defmodule FzHttp.OrgSettingsTest do
  use FzHttp.DataCase, async: false
  # async: false — singleton row + PubSub broadcasts mutate global state.

  alias FzHttp.OrgSettings
  alias FzHttp.{SubjectFixtures, UsersFixtures}

  setup do
    admin = UsersFixtures.create_user_with_role(:admin)
    unpriv = UsersFixtures.create_user_with_role(:unprivileged)

    # Reset toggle to false at start of each test.
    if OrgSettings.l7_enabled?(), do: force_disable()

    on_exit(fn -> force_disable() end)

    %{
      admin_subject: SubjectFixtures.create_subject(admin),
      unpriv_subject: SubjectFixtures.create_subject(unpriv)
    }
  end

  describe "get/0 + l7_enabled?/0" do
    test "seed row is present with l7_enabled = false" do
      settings = OrgSettings.get()
      assert settings.id == 1
      assert settings.l7_enabled == false
      assert OrgSettings.l7_enabled?() == false
    end
  end

  describe "set_l7_enabled/3" do
    test "admin can toggle to true", %{admin_subject: subject} do
      assert {:ok, updated} = OrgSettings.set_l7_enabled(true, subject)
      assert updated.l7_enabled == true
      assert OrgSettings.l7_enabled?() == true
    end

    test "admin can toggle back to false", %{admin_subject: subject} do
      {:ok, _} = OrgSettings.set_l7_enabled(true, subject)
      assert {:ok, updated} = OrgSettings.set_l7_enabled(false, subject)
      assert updated.l7_enabled == false
    end

    test "unprivileged user denied", %{unpriv_subject: subject} do
      assert {:error, _} = OrgSettings.set_l7_enabled(true, subject)
      assert OrgSettings.l7_enabled?() == false
    end

    test "broadcasts on real change", %{admin_subject: subject} do
      OrgSettings.subscribe()

      {:ok, _} = OrgSettings.set_l7_enabled(true, subject)

      assert_receive {:l7_enabled_changed, true}, 1000
    after
      OrgSettings.unsubscribe()
    end

    test "no-op: setting the same value does NOT broadcast",
         %{admin_subject: subject} do
      OrgSettings.subscribe()

      {:ok, _} = OrgSettings.set_l7_enabled(false, subject)
      refute_receive {:l7_enabled_changed, _}, 100
    after
      OrgSettings.unsubscribe()
    end
  end

  # Bypass the audit + permission path so setup teardown doesn't
  # cascade audit log rows across tests.
  defp force_disable do
    settings = OrgSettings.get()

    if settings.l7_enabled do
      settings
      |> FzHttp.OrgSettings.Settings.Changeset.update_changeset(%{l7_enabled: false})
      |> Repo.update!()
    end
  end
end
