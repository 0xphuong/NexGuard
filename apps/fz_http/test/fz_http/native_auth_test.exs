defmodule FzHttp.NativeAuthTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.NativeAuth
  alias FzHttp.UsersFixtures

  # Sample PKCE pair generated once, hardcoded for test determinism.
  # verifier: "test-verifier-1234567890123456789012345678901234567890aa"
  # challenge: BASE64URL(SHA256(verifier))
  @verifier "test-verifier-1234567890123456789012345678901234567890aa"
  @challenge "NbVsp0ndTXZOeKRgvhsAf9xYLLv-A6HAltWKvZdWlXA"

  @redirect_uri "nexguard-connect://callback"

  setup do
    user = UsersFixtures.create_user_with_role(:admin)
    %{user: user}
  end

  describe "create_code/3" do
    test "issues a one-time code", %{user: user} do
      assert {:ok, code} = NativeAuth.create_code(user, @challenge, @redirect_uri)
      assert is_binary(code)
      assert byte_size(code) > 20
    end

    test "rejects non-whitelisted redirect_uri scheme", %{user: user} do
      assert {:error, :invalid_redirect_uri} =
               NativeAuth.create_code(user, @challenge, "https://evil.example.com/cb")
    end

    test "rejects code_challenge too short", %{user: user} do
      assert {:error, :invalid_code_challenge} =
               NativeAuth.create_code(user, "short", @redirect_uri)
    end
  end

  describe "exchange_code/2" do
    test "exchanges valid code + verifier for user", %{user: user} do
      {:ok, code} = NativeAuth.create_code(user, @challenge, @redirect_uri)

      assert {:ok, returned_user, returned_redirect} = NativeAuth.exchange_code(code, @verifier)
      assert returned_user.id == user.id
      assert returned_redirect == @redirect_uri
    end

    test "rejects PKCE mismatch", %{user: user} do
      {:ok, code} = NativeAuth.create_code(user, @challenge, @redirect_uri)

      assert {:error, :pkce_mismatch} = NativeAuth.exchange_code(code, "wrong-verifier")
    end

    test "rejects unknown code" do
      assert {:error, :invalid_code} = NativeAuth.exchange_code("does-not-exist", @verifier)
    end

    test "rejects already-consumed code (one-time use)", %{user: user} do
      {:ok, code} = NativeAuth.create_code(user, @challenge, @redirect_uri)

      assert {:ok, _, _} = NativeAuth.exchange_code(code, @verifier)
      assert {:error, :already_consumed} = NativeAuth.exchange_code(code, @verifier)
    end
  end

  describe "create_refresh_token/2 + validate_refresh_token/1" do
    test "issues plaintext + validates back to user", %{user: user} do
      {:ok, plaintext} = NativeAuth.create_refresh_token(user, %{"user_agent" => "test"})

      assert is_binary(plaintext)
      assert {:ok, validated_user} = NativeAuth.validate_refresh_token(plaintext)
      assert validated_user.id == user.id
    end

    test "rejects unknown token" do
      assert {:error, :not_found} = NativeAuth.validate_refresh_token("does-not-exist")
    end

    test "rejects revoked token", %{user: user} do
      {:ok, plaintext} = NativeAuth.create_refresh_token(user)
      :ok = NativeAuth.revoke_refresh_token(plaintext)

      assert {:error, :revoked} = NativeAuth.validate_refresh_token(plaintext)
    end
  end

  describe "rotate_refresh_token/2" do
    test "issues a new token and revokes the old", %{user: user} do
      {:ok, old} = NativeAuth.create_refresh_token(user)

      assert {:ok, returned_user, new} = NativeAuth.rotate_refresh_token(old)
      assert returned_user.id == user.id
      assert new != old

      # Old now revoked
      assert {:error, :revoked} = NativeAuth.validate_refresh_token(old)
      # New works
      assert {:ok, _} = NativeAuth.validate_refresh_token(new)
    end
  end

  describe "revoke_all_for_user/1" do
    test "revokes every active token for the user", %{user: user} do
      {:ok, t1} = NativeAuth.create_refresh_token(user)
      {:ok, t2} = NativeAuth.create_refresh_token(user)

      assert {:ok, 2} = NativeAuth.revoke_all_for_user(user)

      assert {:error, :revoked} = NativeAuth.validate_refresh_token(t1)
      assert {:error, :revoked} = NativeAuth.validate_refresh_token(t2)
    end
  end
end
