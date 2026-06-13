defmodule FzHttp.NativeAuth do
  @moduledoc """
  OAuth-like flow cho native clients (NexGuard Connect macOS/Windows/Linux/mobile).

  Two-phase auth:
    1. Browser bridge: `/auth/native/begin` redirects user qua existing OIDC (Google).
       Server stores PKCE `code_challenge` + `redirect_uri` (whitelist scheme).
       On OIDC callback success, server creates a one-time `code` and redirects to
       `nexguard-connect://callback?code=...&state=...`.

    2. Token exchange: client `POST /api/v1/native/token` with `{code, code_verifier}`.
       Server verifies SHA256(code_verifier) == code_challenge, marks code consumed,
       returns short-lived access JWT + long-lived refresh token (rotated on use).

  Access tokens are issued via existing Guardian pipeline with a `"native"` claim
  carrying `user_id`. See `FzHttpWeb.Auth.JSON.Authentication`.
  """

  import Ecto.Query

  alias FzHttp.{Repo, Users}
  alias FzHttp.NativeAuth.{NativeAuthCode, NativeRefreshToken}

  @code_ttl_seconds 300
  @refresh_ttl_seconds 60 * 60 * 24 * 30
  @allowed_redirect_schemes ~w(nexguard-connect)

  # ---- Auth codes ----

  @doc """
  Create a one-time code after OIDC completion. Called by the AuthController
  when finishing native flow.

  Returns `{:ok, code}` — the plaintext code to redirect to client URI.
  """
  def create_code(%Users.User{} = user, code_challenge, redirect_uri)
      when is_binary(code_challenge) and is_binary(redirect_uri) do
    with :ok <- validate_redirect_uri(redirect_uri),
         :ok <- validate_code_challenge(code_challenge) do
      code = generate_token(32)
      now = DateTime.utc_now()

      changeset =
        %NativeAuthCode{}
        |> Ecto.Changeset.cast(
          %{
            code: code,
            code_challenge: code_challenge,
            redirect_uri: redirect_uri,
            expires_at: DateTime.add(now, @code_ttl_seconds, :second),
            user_id: user.id
          },
          [:code, :code_challenge, :redirect_uri, :expires_at, :user_id]
        )
        |> Ecto.Changeset.validate_required([
          :code,
          :code_challenge,
          :redirect_uri,
          :expires_at,
          :user_id
        ])

      case Repo.insert(changeset) do
        {:ok, _record} -> {:ok, code}
        {:error, cs} -> {:error, cs}
      end
    end
  end

  @doc """
  Exchange a code + PKCE verifier for a user.

  Returns `{:ok, user, redirect_uri}` on success. Marks code consumed atomically.
  Errors: `:invalid_code | :pkce_mismatch | :already_consumed | :expired`.
  """
  def exchange_code(code, code_verifier)
      when is_binary(code) and is_binary(code_verifier) do
    now = DateTime.utc_now()

    case Repo.get_by(NativeAuthCode, code: code) do
      nil ->
        {:error, :invalid_code}

      %NativeAuthCode{consumed_at: ts} when not is_nil(ts) ->
        {:error, :already_consumed}

      %NativeAuthCode{expires_at: exp} = auth_code ->
        cond do
          DateTime.compare(exp, now) != :gt ->
            {:error, :expired}

          not pkce_match?(auth_code.code_challenge, code_verifier) ->
            {:error, :pkce_mismatch}

          true ->
            auth_code
            |> Ecto.Changeset.change(consumed_at: now)
            |> Repo.update!()

            user = Users.fetch_user_by_id!(auth_code.user_id)
            {:ok, user, auth_code.redirect_uri}
        end
    end
  end

  # ---- Refresh tokens ----

  @doc """
  Issue a refresh token for a user. Returns `{:ok, plaintext}` — the only
  time plaintext is available. Only sha256 hash is persisted.

  `metadata` may include `user_agent`, `remote_ip`, `device_name`.
  """
  def create_refresh_token(%Users.User{} = user, metadata \\ %{}) do
    plaintext = generate_token(32)
    now = DateTime.utc_now()

    changeset =
      %NativeRefreshToken{}
      |> Ecto.Changeset.cast(
        %{
          token_hash: hash_token(plaintext),
          expires_at: DateTime.add(now, @refresh_ttl_seconds, :second),
          client_metadata: metadata,
          user_id: user.id
        },
        [:token_hash, :expires_at, :client_metadata, :user_id]
      )
      |> Ecto.Changeset.validate_required([:token_hash, :expires_at, :user_id])

    case Repo.insert(changeset) do
      {:ok, _record} -> {:ok, plaintext}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc """
  Validate a refresh token (does NOT rotate). Returns `{:ok, user}` or
  `{:error, :not_found | :revoked | :expired}`.

  Updates `last_used_at` for audit.
  """
  def validate_refresh_token(plaintext) when is_binary(plaintext) do
    now = DateTime.utc_now()
    hash = hash_token(plaintext)

    case Repo.get_by(NativeRefreshToken, token_hash: hash) do
      nil ->
        {:error, :not_found}

      %NativeRefreshToken{revoked_at: ts} when not is_nil(ts) ->
        {:error, :revoked}

      %NativeRefreshToken{expires_at: exp} = token ->
        if DateTime.compare(exp, now) != :gt do
          {:error, :expired}
        else
          token = Repo.preload(token, :user)

          token
          |> Ecto.Changeset.change(last_used_at: now)
          |> Repo.update!()

          {:ok, token.user}
        end
    end
  end

  @doc """
  Rotate a refresh token. Revokes old, issues new in a transaction.

  Returns `{:ok, user, new_plaintext}` or error tuple.
  """
  def rotate_refresh_token(plaintext, metadata \\ %{}) when is_binary(plaintext) do
    now = DateTime.utc_now()
    hash = hash_token(plaintext)

    case Repo.get_by(NativeRefreshToken, token_hash: hash) do
      nil ->
        {:error, :not_found}

      %NativeRefreshToken{revoked_at: ts} when not is_nil(ts) ->
        {:error, :revoked}

      %NativeRefreshToken{expires_at: exp} = old ->
        if DateTime.compare(exp, now) != :gt do
          {:error, :expired}
        else
          old = Repo.preload(old, :user)

          Repo.transaction(fn ->
            old
            |> Ecto.Changeset.change(revoked_at: now)
            |> Repo.update!()

            case create_refresh_token(old.user, metadata) do
              {:ok, new_plaintext} -> {old.user, new_plaintext}
              {:error, cs} -> Repo.rollback(cs)
            end
          end)
          |> case do
            {:ok, {user, new_plaintext}} -> {:ok, user, new_plaintext}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  @doc """
  Revoke a refresh token (sign-out from a single device).
  Idempotent — already-revoked returns `:ok`.
  """
  def revoke_refresh_token(plaintext) when is_binary(plaintext) do
    hash = hash_token(plaintext)

    case Repo.get_by(NativeRefreshToken, token_hash: hash) do
      nil ->
        {:error, :not_found}

      %NativeRefreshToken{revoked_at: ts} when not is_nil(ts) ->
        :ok

      token ->
        token
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
        |> Repo.update!()

        :ok
    end
  end

  @doc """
  Revoke ALL refresh tokens for a user (sign-out everywhere).
  """
  def revoke_all_for_user(%Users.User{id: user_id}) do
    now = DateTime.utc_now()

    {count, _} =
      from(t in NativeRefreshToken,
        where: t.user_id == ^user_id and is_nil(t.revoked_at),
        update: [set: [revoked_at: ^now]]
      )
      |> Repo.update_all([])

    {:ok, count}
  end

  # ---- Internal helpers ----

  defp generate_token(byte_count) do
    :crypto.strong_rand_bytes(byte_count) |> Base.url_encode64(padding: false)
  end

  defp hash_token(plaintext) do
    :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
  end

  # PKCE per RFC 7636: code_challenge = BASE64URL(SHA256(code_verifier))
  defp pkce_match?(stored_challenge, code_verifier) do
    computed =
      :crypto.hash(:sha256, code_verifier)
      |> Base.url_encode64(padding: false)

    Plug.Crypto.secure_compare(computed, stored_challenge)
  end

  defp validate_redirect_uri(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme} when scheme in @allowed_redirect_schemes -> :ok
      _ -> {:error, :invalid_redirect_uri}
    end
  end

  # PKCE code_challenge: base64url(SHA256(...)) → 43 chars after padding strip
  defp validate_code_challenge(challenge)
       when byte_size(challenge) >= 43 and byte_size(challenge) <= 128,
       do: :ok

  defp validate_code_challenge(_), do: {:error, :invalid_code_challenge}
end
