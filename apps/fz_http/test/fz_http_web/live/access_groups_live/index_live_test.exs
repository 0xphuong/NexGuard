defmodule FzHttpWeb.AccessGroupsLive.IndexTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttp.AccessGroupsFixtures

  describe "Index mount" do
    test "admin sees the empty state when no groups exist", %{admin_conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/access-groups")

      assert html =~ "No access groups yet"
      assert html =~ "Create first group"
    end

    test "admin sees stats strip + group rows once groups exist", %{admin_conn: conn} do
      _g1 = AccessGroupsFixtures.create_group(%{name: "engineering-test"})
      _g2 = AccessGroupsFixtures.create_group(%{name: "wiki-readers-test"})

      {:ok, _view, html} = live(conn, ~p"/access-groups")

      assert html =~ "Memberships"  # stats strip
      assert html =~ "engineering-test"
      assert html =~ "wiki-readers-test"
    end

    test "unprivileged user cannot mount the page", %{unprivileged_conn: conn} do
      # LiveView mount raises {:redirect, ...} or similar; the conn-level
      # authorization stops it before mount. Either way the LiveView call
      # is not allowed to settle.
      assert {:error, _} = live(conn, ~p"/access-groups")
    end
  end

  describe "Create group flow" do
    test "admin creates a group via the modal", %{admin_conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/access-groups/new")

      view
      |> form("#access-group-form", group: %{name: "live-test-eng", description: "from test"})
      |> render_submit()

      # Form redirects to /access-groups/:id on success — follow the redirect.
      assert_redirected(view, "/access-groups/" <> _id = path)
      {:ok, _show_view, html} = live(conn, path)

      assert html =~ "live-test-eng"
    end

    test "admin gets inline validation on duplicate name", %{admin_conn: conn} do
      _existing = AccessGroupsFixtures.create_group(%{name: "dup-via-live"})

      {:ok, view, _html} = live(conn, ~p"/access-groups/new")

      html =
        view
        |> form("#access-group-form", group: %{name: "dup-via-live"})
        |> render_submit()

      assert html =~ "has already been taken"
    end
  end

  describe "Delete flow" do
    test "deleting a group removes it from the table", %{admin_conn: conn} do
      group = AccessGroupsFixtures.create_group(%{name: "to-delete"})

      {:ok, view, html} = live(conn, ~p"/access-groups")
      assert html =~ "to-delete"

      view
      |> element("button[phx-value-id='#{group.id}']", "")
      |> render_click()

      refute render(view) =~ "to-delete"
    end
  end
end
