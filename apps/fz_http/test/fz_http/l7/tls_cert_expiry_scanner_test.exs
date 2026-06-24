defmodule FzHttp.L7.TlsCertExpiryScannerTest do
  use FzHttp.DataCase, async: false

  alias FzHttp.AuditLogs
  alias FzHttp.L7.TlsCertExpiryScanner
  alias FzHttp.TlsCertificatesFixtures, as: F

  setup do
    {:ok, _pid} = start_supervised(TlsCertExpiryScanner)
    :ok
  end

  describe "scan_now/0" do
    test "categorises certs into expired / critical / soon / skipped" do
      now = DateTime.utc_now()

      _healthy =
        F.create_certificate(%{
          "sans" => ["healthy.test"],
          "primary_san" => "healthy.test",
          "label" => "healthy",
          "not_after" => DateTime.add(now, 100 * 86_400, :second)
        })

      _soon =
        F.create_certificate(%{
          "sans" => ["soon.test"],
          "primary_san" => "soon.test",
          "label" => "soon",
          "not_after" => DateTime.add(now, 20 * 86_400, :second)
        })

      _critical =
        F.create_certificate(%{
          "sans" => ["critical.test"],
          "primary_san" => "critical.test",
          "label" => "critical",
          "not_after" => DateTime.add(now, 5 * 86_400, :second)
        })

      _expired =
        F.create_certificate(%{
          "sans" => ["expired.test"],
          "primary_san" => "expired.test",
          "label" => "expired",
          "not_after" => DateTime.add(now, -1, :day)
        })

      counts = TlsCertExpiryScanner.scan_now()

      # Healthy cert is filtered out by the `not_after <= cutoff_30d`
      # query, so it doesn't even reach classify.
      assert counts.expired  == 1
      assert counts.critical == 1
      assert counts.soon     == 1
    end

    test "writes a tls_cert.expiry_warning audit entry per warning" do
      F.create_certificate(%{
        "sans" => ["alarm.test"],
        "primary_san" => "alarm.test",
        "label" => "alarm",
        "not_after" => DateTime.add(DateTime.utc_now(), 2, :day)
      })

      _ = TlsCertExpiryScanner.scan_now()

      assert [log] = AuditLogs.list_logs(action: "tls_cert.expiry_warning")
      assert log.target_label == "alarm"
      assert log.actor_email == "system"
      assert log.metadata["level"] == "critical"
    end

    test "dedupes — second scan within 24h does not double-write" do
      F.create_certificate(%{
        "label" => "dedupe",
        "not_after" => DateTime.add(DateTime.utc_now(), 3, :day)
      })

      _ = TlsCertExpiryScanner.scan_now()
      assert length(AuditLogs.list_logs(action: "tls_cert.expiry_warning")) == 1

      # Second scan immediately after — should NOT add another entry.
      _ = TlsCertExpiryScanner.scan_now()
      assert length(AuditLogs.list_logs(action: "tls_cert.expiry_warning")) == 1
    end

    test "no warnings for an empty library" do
      counts = TlsCertExpiryScanner.scan_now()
      assert counts == %{expired: 0, critical: 0, soon: 0, skipped: 0}
    end
  end
end
