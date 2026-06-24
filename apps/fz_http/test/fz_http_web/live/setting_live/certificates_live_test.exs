defmodule FzHttpWeb.SettingLive.CertificatesTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttp.L7.{TlsCertificate, TlsCertificates}
  alias FzHttp.Repo
  alias FzHttp.TlsCertificatesFixtures, as: F

  describe "mount" do
    test "empty state when no certs uploaded yet", %{admin_conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/certificates")

      assert html =~ "No certificates uploaded yet"
      assert html =~ "Upload first certificate"
    end

    test "lists certs already in the library", %{admin_conn: conn} do
      _cert = F.create_certificate(%{"label" => "Visible label", "sans" => ["*.visible.test"]})

      {:ok, _view, html} = live(conn, ~p"/settings/certificates")

      assert html =~ "Visible label"
      assert html =~ "*.visible.test"
    end

    test "unprivileged user is blocked", %{unprivileged_conn: conn} do
      assert {:error, _} = live(conn, ~p"/settings/certificates")
    end
  end

  describe "upload modal — /settings/certificates/new" do
    test "saves a new cert and refreshes the list", %{admin_conn: conn} do
      {pem, key} = F.rsa_cert("*.upload-flow.test")

      {:ok, view, _html} = live(conn, ~p"/settings/certificates/new")

      view
      |> form("#certificate-form", tls_certificate: %{
           label: "Upload flow cert",
           pem: pem,
           key: key
         })
      |> render_submit()

      # The form_component send/2's a refresh to the LV, which
      # re-renders with the new entry. The redirect via push_patch
      # takes us back to the list URL.
      html = render(view)
      assert html =~ "Upload flow cert"
      assert html =~ "*.upload-flow.test"

      # And the DB row really exists.
      assert Repo.get_by(TlsCertificate, label: "Upload flow cert")
    end

    test "surfaces parser errors inline", %{admin_conn: conn} do
      {pem, _wrong_key} = F.rsa_cert("a.example.com")
      {_other, key} = F.rsa_cert("b.example.com")

      {:ok, view, _html} = live(conn, ~p"/settings/certificates/new")

      html =
        view
        |> form("#certificate-form", tls_certificate: %{
             label: "Mismatched",
             pem: pem,
             key: key
           })
        |> render_submit()

      assert html =~ "private key does not match"
    end
  end

  describe "delete flow" do
    test "confirm modal blocks delete when an app pins the cert",
         %{admin_conn: conn} do
      cert = F.create_certificate(%{"label" => "Pinned cert"})

      # Insert a pinning app via raw Repo to bypass changeset (we're
      # testing the delete-protection, not app create validation).
      app =
        FzHttp.ApplicationsFixtures.create_application(%{
          "hostname" => "pinned.fixture.local",
          "cert_source" => :library,
          "tls_auto_match" => false
        })

      {:ok, _} =
        app
        |> Ecto.Changeset.change(tls_cert_id: cert.id)
        |> Repo.update()

      {:ok, view, _html} = live(conn, ~p"/settings/certificates")

      view
      |> element("button[phx-value-id='#{cert.id}']")
      |> render_click()

      html = render(view)

      # Modal shows the pinned app — and the Delete button is NOT
      # rendered (blocked).
      assert html =~ "pinned.fixture.local"
      assert html =~ "explicitly pinned"
      refute html =~ "Delete Certificate"
    end

    test "deletes when no app references the cert", %{admin_conn: conn} do
      cert = F.create_certificate(%{"label" => "Free to delete"})

      {:ok, view, _html} = live(conn, ~p"/settings/certificates")

      view
      |> element("button[phx-value-id='#{cert.id}']")
      |> render_click()

      view |> element("button[phx-click='delete']") |> render_click()

      refute Repo.get(TlsCertificate, cert.id)
      assert render(view) =~ "deleted"
    end
  end
end
