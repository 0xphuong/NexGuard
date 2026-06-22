defmodule FzHttp.AuditLogsTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.AuditLogs
  alias FzHttp.AuditLogs.AuditLog

  describe "@valid_actions whitelist" do
    # Every action string the codebase passes to AuditLogs.log/2
    # MUST be in @valid_actions or the row is silently dropped +
    # a Logger.error fires. v3.0.0 shipped with the L7 application
    # actions missing → every admin click triggered audit-log spam.
    # This test pins the catalogue so future audit calls fail loudly
    # at test time rather than at deploy time.
    @must_be_whitelisted ~w(
      l7.signing_key.bootstrap
      l7.signing_key.rotate
      access_group.create
      access_group.update
      access_group.delete
      access_group.add_member
      access_group.remove_member
      application.create
      application.update
      application.delete
      application.enabled.change
      application.allow_group
      application.revoke_group
      org_settings.l7_enabled.change
      user.access_scope.change
    )

    for action <- @must_be_whitelisted do
      test "valid_actions includes #{action}" do
        assert unquote(action) in AuditLog.valid_actions(),
               "action #{unquote(action)} is emitted by the codebase but missing from the whitelist"
      end
    end
  end

  describe "log/2" do
    test "successfully writes a row when action is whitelisted" do
      assert :ok =
               AuditLogs.log("application.create",
                 actor_email: "admin@example.com",
                 target_type: "application",
                 target_id: "00000000-0000-0000-0000-000000000001",
                 metadata: %{hostname: "wiki.internal"}
               )

      assert [row] = AuditLogs.list_logs(action: "application.create")
      assert row.actor_email == "admin@example.com"
      assert row.metadata["hostname"] == "wiki.internal"
    end

    test "silently drops the row when action is NOT whitelisted (legacy safety)" do
      # The contract: log/2 NEVER raises, even on a bad action.
      # Audit failures must not propagate back into the calling
      # mutation path. Verified by capturing log output.
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          assert :ok = AuditLogs.log("this.is.not.a.real.action", actor_email: "x@y")
        end)

      assert log =~ "AuditLogs.log failed"
      assert AuditLogs.list_logs(action: "this.is.not.a.real.action") == []
    end
  end
end
