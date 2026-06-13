defmodule FzHttp.Repo.Migrations.CreateNativeAuthTables do
  use Ecto.Migration

  def change do
    # Native OAuth-like flow: one-time codes exchanged from browser callback to JSON token endpoint.
    # PKCE-protected. Code holds the SHA256(verifier) until client proves possession.
    create table(:native_auth_codes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:code, :text, null: false)
      add(:code_challenge, :text, null: false)
      add(:redirect_uri, :text, null: false)
      add(:expires_at, :timestamptz, null: false)
      add(:consumed_at, :timestamptz)

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      timestamps(updated_at: false)
    end

    create(unique_index(:native_auth_codes, [:code]))
    create(index(:native_auth_codes, [:expires_at]))
    create(index(:native_auth_codes, [:user_id]))

    # Long-lived refresh tokens. Plaintext is shown only at issue time;
    # only sha256 hash is stored.
    create table(:native_refresh_tokens, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:token_hash, :text, null: false)
      add(:expires_at, :timestamptz, null: false)
      add(:revoked_at, :timestamptz)
      add(:last_used_at, :timestamptz)
      add(:client_metadata, :map, null: false, default: %{})

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      timestamps(updated_at: false)
    end

    create(unique_index(:native_refresh_tokens, [:token_hash]))
    create(index(:native_refresh_tokens, [:expires_at]))
    create(index(:native_refresh_tokens, [:user_id]))
  end
end
