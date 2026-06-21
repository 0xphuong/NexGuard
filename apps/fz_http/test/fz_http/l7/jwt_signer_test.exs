defmodule FzHttp.L7.JwtSignerTest do
  # async: false — JwtSigner spawns a GenServer that needs DB access; the
  # shared sandbox mode (set when async is off) lets the child PID reach the
  # test's transaction without a manual Sandbox.allow/3.
  use FzHttp.DataCase, async: false

  alias FzHttp.AuditLogs
  alias FzHttp.L7.{JwtSigner, SigningKey}
  alias FzHttp.Repo
  alias FzHttp.SubjectFixtures

  setup do
    {:ok, signer: start_supervised!(JwtSigner)}
  end

  describe "bootstrap" do
    test "creates a single active RS256 key on first boot", %{signer: signer} do
      kid = JwtSigner.active_kid(signer)
      assert is_binary(kid)

      assert [%SigningKey{kid: ^kid, active: true, algorithm: "RS256"}] =
               Repo.all(SigningKey)
    end

    test "emits an audit log entry tagged 'system'", %{signer: signer} do
      kid = JwtSigner.active_kid(signer)

      assert [log] = AuditLogs.list_logs(action: "l7.signing_key.bootstrap")
      assert log.target_id == kid
      assert log.target_type == "l7_signing_key"
      assert log.actor_email == "system"
      assert log.actor_id == nil
      assert log.metadata["algorithm"] == "RS256"
      assert log.metadata["bits"] == 2048
    end
  end

  describe "sign + verify" do
    test "round-trip preserves caller claims", %{signer: signer} do
      assert {:ok, jws} =
               JwtSigner.sign(signer, %{"sub" => "u-123", "email" => "x@y.z"})

      assert {:ok, claims} = JwtSigner.verify(signer, jws)
      assert claims["sub"] == "u-123"
      assert claims["email"] == "x@y.z"
      assert is_integer(claims["iat"])
      assert is_integer(claims["exp"])
    end

    test "default expires_in is 300 seconds", %{signer: signer} do
      {:ok, jws} = JwtSigner.sign(signer, %{"sub" => "x"})
      {:ok, claims} = JwtSigner.verify(signer, jws)
      assert claims["exp"] - claims["iat"] == 300
    end

    test "custom expires_in overrides default", %{signer: signer} do
      {:ok, jws} = JwtSigner.sign(signer, %{"sub" => "x"}, expires_in: 60)
      {:ok, claims} = JwtSigner.verify(signer, jws)
      assert claims["exp"] - claims["iat"] == 60
    end

    test "tokens past their exp fail verify with :expired", %{signer: signer} do
      {:ok, jws} = JwtSigner.sign(signer, %{"sub" => "x"}, expires_in: -1)
      assert {:error, :expired} = JwtSigner.verify(signer, jws)
    end

    test "tokens with tampered signature fail verify", %{signer: signer} do
      {:ok, jws} = JwtSigner.sign(signer, %{"sub" => "x"})
      [header, payload, sig] = String.split(jws, ".")
      tampered = header <> "." <> payload <> "." <> String.reverse(sig)
      assert {:error, _} = JwtSigner.verify(signer, tampered)
    end
  end

  describe "rotate" do
    test "issues a fresh kid and marks the previous key rotated", %{signer: signer} do
      old_kid = JwtSigner.active_kid(signer)
      assert {:ok, new_kid} = JwtSigner.rotate(signer, nil, nil)

      refute new_kid == old_kid
      assert JwtSigner.active_kid(signer) == new_kid

      old = Repo.get_by(SigningKey, kid: old_kid)
      assert old.active == false
      assert old.rotated_at != nil
    end

    test "tokens signed by the previous key still verify (grace window)", %{signer: signer} do
      {:ok, jws_old} = JwtSigner.sign(signer, %{"sub" => "still-good"})
      {:ok, _new_kid} = JwtSigner.rotate(signer, nil, nil)

      assert {:ok, %{"sub" => "still-good"}} = JwtSigner.verify(signer, jws_old)
    end

    test "audit row captures actor when a subject is supplied", %{signer: signer} do
      subject = SubjectFixtures.create_subject()
      {:user, user} = subject.actor

      old_kid = JwtSigner.active_kid(signer)
      {:ok, new_kid} = JwtSigner.rotate(signer, subject, {10, 0, 0, 5})

      assert [log] = AuditLogs.list_logs(action: "l7.signing_key.rotate")
      assert log.actor_id == user.id
      assert log.actor_email == user.email
      assert log.target_id == new_kid
      assert log.metadata["retired_kid"] == old_kid
      assert log.metadata["new_kid"] == new_kid
    end

    test "audit row marks 'system' when no subject is supplied", %{signer: signer} do
      {:ok, _new_kid} = JwtSigner.rotate(signer, nil, nil)

      assert [log] = AuditLogs.list_logs(action: "l7.signing_key.rotate")
      assert log.actor_id == nil
      assert log.actor_email == "system"
    end
  end

  describe "active_signing_material" do
    test "returns the active key's kid + algorithm + decrypted private pem", %{signer: signer} do
      kid = JwtSigner.active_kid(signer)

      assert %{kid: ^kid, algorithm: "RS256", private_pem: pem} =
               JwtSigner.active_signing_material(signer)

      assert is_binary(pem)
      # The private PEM should be RSA (or PKCS#8 with RSA inside); reject the
      # public projection slipping through by checking for a PRIVATE marker.
      assert pem =~ "PRIVATE KEY"
    end

    test "follows the active key across a rotation", %{signer: signer} do
      old_pem = JwtSigner.active_signing_material(signer).private_pem
      {:ok, new_kid} = JwtSigner.rotate(signer, nil, nil)

      mat = JwtSigner.active_signing_material(signer)
      assert mat.kid == new_kid
      refute mat.private_pem == old_pem
    end
  end

  describe "jwks" do
    test "returns only the active key on first boot", %{signer: signer} do
      kid = JwtSigner.active_kid(signer)
      assert [jwk] = JwtSigner.jwks(signer)

      assert jwk["kid"] == kid
      assert jwk["kty"] == "RSA"
      assert jwk["alg"] == "RS256"
      assert jwk["use"] == "sig"
      assert jwk["e"] == "AQAB"
      assert is_binary(jwk["n"])
    end

    test "returns active + rotated keys after rotation", %{signer: signer} do
      old_kid = JwtSigner.active_kid(signer)
      {:ok, new_kid} = JwtSigner.rotate(signer, nil, nil)

      kids = JwtSigner.jwks(signer) |> Enum.map(& &1["kid"])
      assert new_kid in kids
      assert old_kid in kids
      assert length(kids) == 2
    end
  end
end
