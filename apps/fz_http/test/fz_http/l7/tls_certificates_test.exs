defmodule FzHttp.L7.TlsCertificatesTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.{AuditLogs, Repo}
  alias FzHttp.Applications.Application
  alias FzHttp.L7.{TlsCertificate, TlsCertificates}
  alias FzHttp.{SubjectFixtures, UsersFixtures, ApplicationsFixtures}
  alias FzHttp.TlsCertificatesFixtures, as: F

  setup do
    admin = UsersFixtures.create_user_with_role(:admin)

    %{
      admin: admin,
      admin_subject: SubjectFixtures.create_subject(admin)
    }
  end

  describe "create_certificate/3" do
    test "parses the PEM and populates denormalised fields",
         %{admin_subject: subject} do
      {pem, key} =
        F.rsa_cert("*.example.com", sans: ["*.example.com", "example.com"])

      assert {:ok, %TlsCertificate{} = cert} =
               TlsCertificates.create_certificate(
                 %{"label" => "Example wildcard", "pem" => pem, "key" => key},
                 subject
               )

      assert cert.label == "Example wildcard"
      assert "*.example.com" in cert.sans
      assert "example.com" in cert.sans
      assert %DateTime{} = cert.not_after
    end

    test "fires a tls_cert.create audit log row",
         %{admin: admin, admin_subject: subject} do
      {pem, key} = F.rsa_cert("a.example.com")

      {:ok, cert} =
        TlsCertificates.create_certificate(
          %{"label" => "Audit me", "pem" => pem, "key" => key},
          subject
        )

      assert [log] = AuditLogs.list_logs(action: "tls_cert.create")
      assert log.actor_id == admin.id
      assert log.target_id == cert.id
      assert log.target_type == "tls_certificate"
      assert log.target_label == "Audit me"
    end

    test "rejects mismatched key", %{admin_subject: subject} do
      {pem, _wrong_key} = F.rsa_cert("a.example.com")
      {_other, key} = F.rsa_cert("b.example.com")

      assert {:error, %Ecto.Changeset{} = cs} =
               TlsCertificates.create_certificate(
                 %{"label" => "Broken", "pem" => pem, "key" => key},
                 subject
               )

      assert errors_on(cs).key != []
    end

    test "enforces label uniqueness", %{admin_subject: subject} do
      {pem, key} = F.rsa_cert("a.example.com")

      {:ok, _} =
        TlsCertificates.create_certificate(
          %{"label" => "Dup", "pem" => pem, "key" => key},
          subject
        )

      {pem2, key2} = F.rsa_cert("b.example.com")

      assert {:error, %Ecto.Changeset{} = cs} =
               TlsCertificates.create_certificate(
                 %{"label" => "Dup", "pem" => pem2, "key" => key2},
                 subject
               )

      assert errors_on(cs).label != []
    end
  end

  describe "replace_certificate/4 — in-place update keeps id" do
    test "the row id does not change", %{admin_subject: subject} do
      {pem1, key1} = F.rsa_cert("a.example.com")

      {:ok, before_cert} =
        TlsCertificates.create_certificate(
          %{"label" => "Renewable", "pem" => pem1, "key" => key1},
          subject
        )

      {pem2, key2} = F.rsa_cert("a.example.com")

      {:ok, after_cert} =
        TlsCertificates.replace_certificate(
          before_cert,
          %{"pem" => pem2, "key" => key2},
          subject
        )

      # Same row id — apps with FK to this cert stay valid.
      assert after_cert.id == before_cert.id

      # But the cert material changed.
      assert after_cert.pem != before_cert.pem
    end

    test "writes a tls_cert.replace audit entry",
         %{admin_subject: subject} do
      cert = F.create_certificate()

      {pem, key} = F.rsa_cert("renewed.example.com")

      {:ok, _} =
        TlsCertificates.replace_certificate(
          cert,
          %{"pem" => pem, "key" => key},
          subject
        )

      assert [_replace] = AuditLogs.list_logs(action: "tls_cert.replace")
    end
  end

  describe "delete_certificate/3" do
    test "deletes when no app references it",
         %{admin_subject: subject} do
      cert = F.create_certificate()

      assert {:ok, _} = TlsCertificates.delete_certificate(cert, subject)
      assert Repo.get(TlsCertificate, cert.id) == nil
    end

    test "BLOCKS delete when an app pins via tls_cert_id",
         %{admin_subject: subject} do
      cert = F.create_certificate()

      # Insert an app that explicitly pins this cert. We bypass the
      # context's validation hop (which would try to look up the cert
      # and verify hostname coverage) by using the fixture directly +
      # raw cast — this isn't testing app create, it's testing that
      # the FK protection kicks in on delete.
      app =
        ApplicationsFixtures.create_application(%{
          "cert_source" => :library,
          "tls_auto_match" => false
        })

      {:ok, _} =
        app
        |> Ecto.Changeset.change(tls_cert_id: cert.id)
        |> Repo.update()

      assert {:error, {:pinned_apps_exist, hostnames}} =
               TlsCertificates.delete_certificate(cert, subject)

      assert app.hostname in hostnames
      # And the cert is still there.
      assert Repo.get(TlsCertificate, cert.id) != nil
    end
  end

  describe "affected_apps/1" do
    test "splits pinned vs auto-matched" do
      cert = F.create_certificate(%{"sans" => ["*.split-affected.test"]})

      # Pinned via FK.
      pinned_app =
        ApplicationsFixtures.create_application(%{
          "hostname" => "pin.split-affected.test",
          "cert_source" => :library,
          "tls_auto_match" => false
        })

      {:ok, _} =
        pinned_app
        |> Ecto.Changeset.change(tls_cert_id: cert.id)
        |> Repo.update()

      # Auto-match: hostname covered by SAN, no explicit FK.
      auto_app =
        ApplicationsFixtures.create_application(%{
          "hostname" => "auto.split-affected.test",
          "cert_source" => :library,
          "tls_auto_match" => true
        })

      result = TlsCertificates.affected_apps(cert)

      assert Enum.any?(result.pinned, &(&1.id == pinned_app.id))
      assert Enum.any?(result.auto_matched, &(&1.id == auto_app.id))

      # And they shouldn't overlap.
      refute Enum.any?(result.pinned, &(&1.id == auto_app.id))
      refute Enum.any?(result.auto_matched, &(&1.id == pinned_app.id))
    end
  end

  describe "PubSub broadcast" do
    test "create_certificate broadcasts :certs_changed",
         %{admin_subject: subject} do
      :ok = TlsCertificates.subscribe()

      {pem, key} = F.rsa_cert("a.example.com")

      {:ok, _} =
        TlsCertificates.create_certificate(
          %{"label" => "Broadcast Me", "pem" => pem, "key" => key},
          subject
        )

      assert_receive :certs_changed, 500

      :ok = TlsCertificates.unsubscribe()
    end
  end
end
