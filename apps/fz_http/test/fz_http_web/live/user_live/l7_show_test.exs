defmodule FzHttpWeb.UserLive.L7ShowTest do
  use FzHttpWeb.ConnCase, async: true
  # Focused tests for the L7 surfaces added to UserLive.Show in Wave 2
  # — Group Memberships card + L7 Access Scope card.

  alias FzHttp.{AccessGroupsFixtures, UsersFixtures}

  describe "Group Memberships card" do
    test "shows 'no groups yet' hint when none exist", %{admin_conn: conn, admin_user: admin} do
      {:ok, _view, html} = live(conn, ~p"/users/#{admin}")

      assert html =~ "Group Memberships"
      assert html =~ "No access groups defined yet" or html =~ "Not in any groups"
    end

    test "admin can add user to a group", %{admin_conn: conn, admin_user: admin} do
      group = AccessGroupsFixtures.create_group(%{name: "live-mship-test"})

      {:ok, view, _html} = live(conn, ~p"/users/#{admin}")

      view
      |> form("#add-to-group-form", %{"group_id" => group.id})
      |> render_submit()

      assert render(view) =~ "live-mship-test"
    end

    test "admin removes user from a group via styled modal", %{admin_conn: conn, admin_user: admin} do
      group = AccessGroupsFixtures.create_group(%{name: "remove-via-modal"})

      # Pre-add via context to avoid coupling this test to add flow.
      subject =
        FzHttp.SubjectFixtures.create_subject(
          UsersFixtures.create_user_with_role(:admin)
        )

      {:ok, _} = FzHttp.AccessGroups.add_member(group, admin, subject)

      {:ok, view, html} = live(conn, ~p"/users/#{admin}")
      assert html =~ "remove-via-modal"

      view
      |> element("button[phx-value-group_id='#{group.id}']")
      |> render_click()

      # Modal must now be visible.
      assert render(view) =~ "Remove from Group"

      # Confirm.
      view |> element("button[phx-click='remove_from_group']") |> render_click()

      refute render(view) =~ "remove-via-modal"
    end
  end

  describe "L7 Access Scope card" do
    test "default is :limited with quiet badge", %{admin_conn: conn, admin_user: admin} do
      {:ok, _view, html} = live(conn, ~p"/users/#{admin}")

      assert html =~ "L7 Access Scope"
      assert html =~ "ng-scope-badge--limited"
      assert html =~ "Grant bypass (set to ALL)"
    end

    test "admin flips to ALL via confirmation modal", %{admin_conn: conn, admin_user: admin} do
      {:ok, view, _html} = live(conn, ~p"/users/#{admin}")

      view
      |> element("button[phx-value-scope='all']")
      |> render_click()

      # Modal visible with break-glass warning.
      assert render(view) =~ "Grant L7 Access Bypass"
      assert render(view) =~ "break-glass"

      # Confirm.
      view |> element("button[phx-click='set_access_scope']") |> render_click()

      html = render(view)
      assert html =~ "ng-scope-badge--all"
      assert html =~ "Revert to LIMITED"
    end
  end
end
