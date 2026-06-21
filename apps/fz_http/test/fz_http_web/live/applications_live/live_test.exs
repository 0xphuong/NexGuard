defmodule FzHttpWeb.ApplicationsLive.LiveTest do
  use FzHttpWeb.ConnCase, async: true
  # Wave 3 surfaces — list, form, allowed groups picker, rules editor.

  alias FzHttp.{ApplicationsFixtures, AccessGroupsFixtures}

  describe "Index" do
    test "shows empty state when no apps", %{admin_conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/applications")

      assert html =~ "No applications yet"
      assert html =~ "Declare first application"
    end

    test "shows stats strip + row once an app exists", %{admin_conn: conn} do
      _app = ApplicationsFixtures.create_application(%{
               "name" => "Index-Test App",
               "hostname" => "index-test-app.fixture.local"
             })

      {:ok, _view, html} = live(conn, ~p"/applications")

      assert html =~ "Total apps"
      assert html =~ "Index-Test App"
      assert html =~ "index-test-app.fixture.local"
    end
  end

  describe "New Application form" do
    test "step_ca path creates an app without cert PEM", %{admin_conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/applications/new")

      view
      |> form("#application-form",
           application: %{
             name: "Form-Test Wiki",
             description: "fixture",
             hostname: "form-test-wiki.fixture.local",
             backend: "https://10.0.50.99",
             cert_source: "step_ca"
           })
      |> render_submit()

      # Redirects to /applications/:id on success.
      assert_redirected(view, "/applications/" <> _ = path)
      {:ok, _, html} = live(conn, path)
      assert html =~ "Form-Test Wiki"
    end

    test "validation surfaces invalid hostname inline", %{admin_conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/applications/new")

      html =
        view
        |> form("#application-form",
             application: %{
               name: "Bad Host",
               hostname: "not a real hostname",
               backend: "https://x",
               cert_source: "step_ca"
             })
        |> render_submit()

      assert html =~ "valid DNS hostname"
    end
  end

  describe "Show page — Allowed Groups picker" do
    test "admin allows a group via dropdown", %{admin_conn: conn} do
      app = ApplicationsFixtures.create_application(%{"hostname" => "allow-test.fixture.local"})
      group = AccessGroupsFixtures.create_group(%{name: "allow-via-live"})

      {:ok, view, _html} = live(conn, ~p"/applications/#{app}")

      view
      |> form("#add-allowed-group-form", %{"group_id" => group.id})
      |> render_submit()

      assert render(view) =~ "allow-via-live"
    end
  end

  describe "Show page — L7 Rules editor" do
    test "admin adds an allow rule with method + path", %{admin_conn: conn} do
      app = ApplicationsFixtures.create_application(%{"hostname" => "rules-test.fixture.local"})

      {:ok, view, _html} = live(conn, ~p"/applications/#{app}")

      view
      |> form("#add-rule-form", %{
           "action" => "allow",
           "method_GET" => "1",
           "method_POST" => "1",
           "path_prefix" => "/api/",
           "require_mfa_age_seconds" => ""
         })
      |> render_submit()

      html = render(view)
      assert html =~ "allow"
      assert html =~ "GET, POST"
      assert html =~ "/api/"
    end

    test "implicit-deny row is always present", %{admin_conn: conn} do
      app = ApplicationsFixtures.create_application(%{"hostname" => "deny-test.fixture.local"})

      {:ok, _view, html} = live(conn, ~p"/applications/#{app}")

      assert html =~ "Implicit default deny"
    end
  end
end
