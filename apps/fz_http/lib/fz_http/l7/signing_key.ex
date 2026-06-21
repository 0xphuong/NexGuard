defmodule FzHttp.L7.SigningKey do
  @moduledoc """
  Persisted RS256 keypair used to sign the `X-NexGuard-Identity-Jwt`
  header the L7 proxy (L7-D) injects into upstream requests (ADR-010).

  Exactly one row has `active = true` at any time (enforced by partial
  unique index `l7_signing_keys_one_active`). Old keys are kept so the
  proxy can verify tokens issued just before a rotation — see
  `FzHttp.L7.JwtSigner` for the grace-window logic.
  """
  use FzHttp, :schema

  schema "l7_signing_keys" do
    field :kid,         :string
    field :algorithm,   :string, default: "RS256"
    # private_pem is encrypted at rest via Cloak. The DB only ever sees
    # ciphertext bytes; plaintext lives only inside the JwtSigner
    # GenServer state.
    field :private_pem, FzHttp.Encrypted.Binary, redact: true
    field :public_pem,  :string
    field :active,      :boolean, default: false
    field :rotated_at,  :utc_datetime_usec

    timestamps()
  end
end
