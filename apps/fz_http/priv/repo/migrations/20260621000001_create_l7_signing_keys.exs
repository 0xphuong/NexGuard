defmodule FzHttp.Repo.Migrations.CreateL7SigningKeys do
  use Ecto.Migration

  @doc """
  RSA keypair store for L7 identity-header JWTs (ADR-010).

  The L7 proxy (L7-D) signs the `X-NexGuard-Identity-Jwt` header
  it injects into upstream requests. Backends verify the signature
  by fetching `/.well-known/jwks.json` and matching by `kid`.

  Schema notes:
    * `kid` is the public key identifier embedded in JWS headers and
      surfaced in JWKS; rotate-friendly (caller picks new keypair, old
      one stays around to verify in-flight tokens).
    * `private_pem` is `bytea` because the application layer encrypts
      it at rest via `FzHttp.Encrypted.Binary` (Cloak). The DB never
      sees plaintext.
    * `active boolean` flagged the current signing key. A **partial
      unique index on `active = true`** enforces "exactly one active
      key at a time" — flipping a new key active requires
      simultaneously deactivating the previous (handled in the
      `FzHttp.L7.JwtSigner.rotate/0` transaction).
    * `rotated_at` stamps when a key was retired (`active` flipped to
      false). NULL on the currently-active row.
    * Inactive keys are **kept**, not deleted — the proxy needs them
      to verify tokens issued before the rotation (grace window
      defined in JwtSigner).
  """
  def change do
    create table(:l7_signing_keys, primary_key: false) do
      add :id,           :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :kid,          :string,    null: false
      add :algorithm,    :string,    null: false, default: "RS256"
      add :private_pem,  :binary,    null: false
      add :public_pem,   :text,      null: false
      add :active,       :boolean,   null: false, default: false
      add :rotated_at,   :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # `kid` shows up in every signed JWT header; lookups by kid during
    # verification MUST be fast even when many old keys are kept.
    create unique_index(:l7_signing_keys, [:kid])

    # Partial unique on `active = true` enforces single-active-key.
    # Postgres handles this natively — Ecto's `where:` opt is just
    # passed through to the CREATE INDEX statement.
    create unique_index(:l7_signing_keys, [:active],
             name: :l7_signing_keys_one_active,
             where: "active = true")
  end
end
