defmodule FzHttp.ApplicationsTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.Applications
  alias FzHttp.Applications.Application
  alias FzHttp.{ApplicationsFixtures, AccessGroupsFixtures, SubjectFixtures, UsersFixtures}

  setup do
    admin = UsersFixtures.create_user_with_role(:admin)
    unpriv = UsersFixtures.create_user_with_role(:unprivileged)

    %{
      admin: admin,
      admin_subject: SubjectFixtures.create_subject(admin),
      unpriv_subject: SubjectFixtures.create_subject(unpriv)
    }
  end

  describe "create_application/3" do
    test "allocates a VIP inside 10.99.0.0/16 and persists",
         %{admin_subject: subject} do
      attrs = %{
        "name" => "Wiki",
        "hostname" => "wiki-create.test.local",
        "backend" => "https://10.0.50.5",
        "cert_source" => :step_ca
      }

      assert {:ok, %Application{} = app} = Applications.create_application(attrs, subject)
      assert {10, 99, _, _} = app.virtual_ip.address
      assert app.hostname == "wiki-create.test.local"
      assert app.enabled == false
      assert app.tls_mode == :terminate
    end

    test "normalises hostname to lower-case", %{admin_subject: subject} do
      {:ok, app} =
        Applications.create_application(
          %{
            "name" => "MX",
            "hostname" => "MiXed.Test.Local",
            "backend" => "https://x",
            "cert_source" => :step_ca
          },
          subject
        )

      assert app.hostname == "mixed.test.local"
    end

    test "rejects invalid hostname", %{admin_subject: subject} do
      assert {:error, cs} =
               Applications.create_application(
                 %{
                   "name" => "Bad",
                   "hostname" => "not a valid hostname",
                   "backend" => "https://x",
                   "cert_source" => :step_ca
                 },
                 subject
               )

      assert errors_on(cs).hostname != []
    end

    test "rejects backend without http:// or https://", %{admin_subject: subject} do
      assert {:error, cs} =
               Applications.create_application(
                 %{
                   "name" => "Bad",
                   "hostname" => "bad-backend.test.local",
                   "backend" => "ftp://example.com",
                   "cert_source" => :step_ca
                 },
                 subject
               )

      assert errors_on(cs).backend != []
    end

    test "cert_source = upload requires cert + key", %{admin_subject: subject} do
      assert {:error, cs} =
               Applications.create_application(
                 %{
                   "name" => "Need Cert",
                   "hostname" => "need-cert.test.local",
                   "backend" => "https://x",
                   "cert_source" => :upload
                 },
                 subject
               )

      assert errors_on(cs)[:cert_pem] != nil
      assert errors_on(cs)[:key_pem] != nil
    end

    test "duplicate hostname rejected", %{admin_subject: subject} do
      base = %{
        "name" => "First",
        "hostname" => "dup-app.test.local",
        "backend" => "https://x",
        "cert_source" => :step_ca
      }

      assert {:ok, _} = Applications.create_application(base, subject)
      assert {:error, cs} = Applications.create_application(base, subject)
      assert errors_on(cs).hostname != []
    end

    test "passthrough TLS rejected in v1", %{admin_subject: subject} do
      assert {:error, cs} =
               Applications.create_application(
                 %{
                   "name" => "PT",
                   "hostname" => "pt.test.local",
                   "backend" => "https://x",
                   "cert_source" => :step_ca,
                   "tls_mode" => :passthrough
                 },
                 subject
               )

      assert errors_on(cs).tls_mode != []
    end

    test "unprivileged user denied", %{unpriv_subject: subject} do
      assert {:error, _} =
               Applications.create_application(
                 %{
                   "name" => "Nope",
                   "hostname" => "nope.test.local",
                   "backend" => "https://x",
                   "cert_source" => :step_ca
                 },
                 subject
               )
    end
  end

  describe "l7_rules validation" do
    test "valid rule shape accepted", %{admin_subject: subject} do
      assert {:ok, app} =
               Applications.create_application(
                 %{
                   "name" => "Rules OK",
                   "hostname" => "rules-ok.test.local",
                   "backend" => "https://x",
                   "cert_source" => :step_ca,
                   "l7_rules" => [
                     %{
                       "method" => ["GET", "POST"],
                       "path_prefix" => "/api/",
                       "action" => "allow"
                     },
                     %{"action" => "deny"}
                   ]
                 },
                 subject
               )

      assert length(app.l7_rules) == 2
    end

    test "rule with bad action rejected", %{admin_subject: subject} do
      assert {:error, cs} =
               Applications.create_application(
                 %{
                   "name" => "Bad Rule",
                   "hostname" => "bad-rule.test.local",
                   "backend" => "https://x",
                   "cert_source" => :step_ca,
                   "l7_rules" => [%{"action" => "bogus"}]
                 },
                 subject
               )

      assert errors_on(cs).l7_rules != []
    end

    test "rule with non-list method rejected", %{admin_subject: subject} do
      assert {:error, cs} =
               Applications.create_application(
                 %{
                   "name" => "Bad Method",
                   "hostname" => "bad-method.test.local",
                   "backend" => "https://x",
                   "cert_source" => :step_ca,
                   "l7_rules" => [%{"action" => "allow", "method" => "GET"}]
                 },
                 subject
               )

      assert errors_on(cs).l7_rules != []
    end
  end

  describe "set_application_enabled/4" do
    test "enabling without an L7 rule refused", %{admin_subject: subject} do
      app = ApplicationsFixtures.create_application_via_context()

      assert {:error, cs} = Applications.set_application_enabled(app, true, subject)
      assert errors_on(cs)[:enabled] != nil
    end

    test "no-op when value matches current state", %{admin_subject: subject} do
      app = ApplicationsFixtures.create_application_via_context()
      assert {:ok, ^app} = Applications.set_application_enabled(app, false, subject)
    end
  end

  describe "list_enabled_for_bundle/0 (system call)" do
    test "returns only enabled apps with allowed_groups preloaded" do
      enabled = ApplicationsFixtures.create_application(%{
        "hostname" => "bundle-enabled.test.local",
        "enabled" => true
      })

      _disabled = ApplicationsFixtures.create_application(%{
        "hostname" => "bundle-disabled.test.local"
      })

      apps = Applications.list_enabled_for_bundle()
      ids = Enum.map(apps, & &1.id)

      assert enabled.id in ids
      assert Enum.all?(apps, & &1.enabled)
      assert Enum.all?(apps, &Ecto.assoc_loaded?(&1.allowed_groups))
    end
  end

  describe "add_allowed_group/4 + remove_allowed_group/4" do
    test "round-trip allowed group membership", %{admin_subject: subject} do
      app = ApplicationsFixtures.create_application()
      group = AccessGroupsFixtures.create_group()

      assert {:ok, _link} = Applications.add_allowed_group(app, group, subject)
      assert {:ok, :removed} = Applications.remove_allowed_group(app, group, subject)
    end

    test "duplicate allow rejected", %{admin_subject: subject} do
      app = ApplicationsFixtures.create_application()
      group = AccessGroupsFixtures.create_group()
      {:ok, _} = Applications.add_allowed_group(app, group, subject)

      assert {:error, _cs} = Applications.add_allowed_group(app, group, subject)
    end
  end

  describe "delete_application/3" do
    test "removes the row and cascades application_allowed_groups",
         %{admin_subject: subject} do
      app = ApplicationsFixtures.create_application()
      group = AccessGroupsFixtures.create_group()
      {:ok, _} = Applications.add_allowed_group(app, group, subject)

      assert {:ok, _} = Applications.delete_application(app, subject)
      assert Repo.get(Application, app.id) == nil
    end
  end
end
