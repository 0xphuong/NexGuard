defmodule FzHttpWeb.SettingLive.L7Test do
  use FzHttpWeb.ConnCase, async: false
  # async: false — toggles the singleton org_settings row that other
  # suites may also be reading.

  alias FzHttp.OrgSettings

  setup do
    # Reset to disabled at the start of each test so the page renders
    # the "Enable L7" affordance.
    if OrgSettings.l7_enabled?(),
      do:
        OrgSettings.get()
        |> FzHttp.OrgSettings.Settings.Changeset.update_changeset(%{l7_enabled: false})
        |> FzHttp.Repo.update!()

    on_exit(fn ->
      if OrgSettings.l7_enabled?(),
        do:
          OrgSettings.get()
          |> FzHttp.OrgSettings.Settings.Changeset.update_changeset(%{l7_enabled: false})
          |> FzHttp.Repo.update!()
    end)

    :ok
  end

  describe "mount" do
    test "admin sees DISABLED state by default", %{admin_conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/l7")

      assert html =~ "L7 Enforcement"
      assert html =~ "DISABLED"
      assert html =~ "Enable L7"
    end

    test "unprivileged user is blocked", %{unprivileged_conn: conn} do
      assert {:error, _} = live(conn, ~p"/settings/l7")
    end
  end

  describe "Enable / Disable flow" do
    test "admin enables L7 via confirmation modal", %{admin_conn: conn} do
      OrgSettings.subscribe()

      {:ok, view, _html} = live(conn, ~p"/settings/l7")

      view |> element("button", "Enable L7") |> render_click()
      # Modal is now visible; clicking Apply commits the flip.
      view |> element("button[phx-click='apply']") |> render_click()

      assert render(view) =~ "ENABLED"
      assert render(view) =~ "L7 is active"
      assert OrgSettings.l7_enabled?() == true

      assert_receive {:l7_enabled_changed, true}, 1000
    after
      OrgSettings.unsubscribe()
    end

    test "Disable broadcasts on PubSub", %{admin_conn: conn} do
      # Start enabled.
      {:ok, _} = OrgSettings.set_l7_enabled(true, FzHttp.SubjectFixtures.create_subject(
                       FzHttp.UsersFixtures.create_user_with_role(:admin)))

      OrgSettings.subscribe()

      {:ok, view, _html} = live(conn, ~p"/settings/l7")
      view |> element("button", "Disable L7") |> render_click()
      view |> element("button[phx-click='apply']") |> render_click()

      assert render(view) =~ "DISABLED"
      assert OrgSettings.l7_enabled?() == false

      assert_receive {:l7_enabled_changed, false}, 1000
    after
      OrgSettings.unsubscribe()
    end
  end
end
