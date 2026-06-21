defmodule FzHttp.L7.JwtSigner do
  @moduledoc """
  GenServer that owns the active RS256 signing key + a small grace
  window of recently-rotated keys (for verification).

  Cold-boot behaviour:
    1. Query `l7_signing_keys WHERE active = true`.
    2. If a row exists, decrypt + load it.
    3. If no active row exists (first boot ever, or a botched
       rotation), **bootstrap** one — generate a new RS256 keypair,
       insert with `active = true`, audit `l7.signing_key.bootstrap`.

  Rotation (`rotate/0`):
    Runs inside a single transaction:
      * Flip current active → inactive + stamp `rotated_at = now()`.
      * Insert new keypair with `active = true`.
    Then `GenServer.call(:reload)` refreshes in-memory state.

  Verification window: the last `@grace_size` rotated keys remain in
  memory so an in-flight JWT signed by the previous key can still
  verify after a rotation. Anything older is dropped from memory but
  retained in the DB.

  Signing is the hot path (called once per L7 proxy request once
  the proxy lands). Verify is called only when a backend chooses to
  verify the injected JWT; backends that just read plain headers
  ignore the JWT entirely.
  """

  use GenServer

  alias FzHttp.{Repo, AuditLogs}
  alias FzHttp.L7.SigningKey
  import Ecto.Query

  # How many recently-rotated keys to keep in memory for verify.
  @grace_size 3

  # Default RSA modulus size. 2048 is the OWASP minimum + JOSE/JWA
  # baseline; 3072 / 4096 noticeably slow down sign() on commodity
  # hardware without a meaningful security uplift for the IAP use
  # case (tokens expire within minutes).
  @rsa_bits 2048

  # ── Client API ─────────────────────────────────────────────────
  #
  # Each public function has two arities. The lower arity targets the
  # supervised singleton registered as `__MODULE__`; the higher arity
  # takes an explicit `server` (pid or registered name) so tests can
  # spawn isolated instances under `start_supervised!/1`. Mirrors the
  # convention in `FzHttp.Notifications`.

  def start_link(opts \\ []) do
    if opts[:name] do
      GenServer.start_link(__MODULE__, opts, name: opts[:name])
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Sign a claims map. Adds `iat` + `exp` if not present.
  Returns `{:ok, compact_jws}` or `{:error, reason}`.

  `expires_in` (seconds) defaults to 5 minutes — short enough to
  bound replay risk if a header leaks, long enough to survive proxy
  upstream connection retries.
  """
  def sign(claims, opts \\ []) when is_map(claims),
    do: sign(__MODULE__, claims, opts)

  def sign(server, claims, opts) when is_map(claims),
    do: GenServer.call(server, {:sign, claims, opts})

  @doc """
  Verify a compact JWS against active + grace keys. Returns
  `{:ok, claims}` on success, `{:error, reason}` otherwise.
  """
  def verify(compact) when is_binary(compact),
    do: verify(__MODULE__, compact)

  def verify(server, compact) when is_binary(compact),
    do: GenServer.call(server, {:verify, compact})

  @doc "Currently-active kid (for `kid` header in signed JWTs)."
  def active_kid, do: active_kid(__MODULE__)
  def active_kid(server), do: GenServer.call(server, :active_kid)

  @doc """
  JWKS payload for `/.well-known/jwks.json` — active + grace keys'
  public halves, RFC 7517 format. Returns a list of maps suitable
  for `{"keys": [...]}` wrapping at the controller layer.
  """
  def jwks, do: jwks(__MODULE__)
  def jwks(server), do: GenServer.call(server, :jwks)

  @doc """
  Generate a fresh keypair, deactivate the previous, return
  `{:ok, new_kid}`. Optional `subject` for audit attribution.
  """
  def rotate(subject \\ nil, ip_address \\ nil),
    do: rotate(__MODULE__, subject, ip_address)

  def rotate(server, subject, ip_address),
    do: GenServer.call(server, {:rotate, subject, ip_address})

  # ── Server callbacks ───────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    state =
      case load_active() do
        nil ->
          # First boot — bootstrap.
          {:ok, key} = generate_and_insert(active?: true)
          audit_bootstrap(key)
          %{active: key, grace: []}

        active ->
          %{active: active, grace: load_grace()}
      end

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:sign, claims, opts}, _from, state) do
    {:reply, do_sign(state.active, claims, opts), state}
  end

  @impl GenServer
  def handle_call({:verify, compact}, _from, state) do
    {:reply, do_verify(compact, [state.active | state.grace]), state}
  end

  @impl GenServer
  def handle_call(:active_kid, _from, state),
    do: {:reply, state.active.kid, state}

  @impl GenServer
  def handle_call(:jwks, _from, state) do
    payload = Enum.map([state.active | state.grace], &public_jwk/1)
    {:reply, payload, state}
  end

  @impl GenServer
  def handle_call({:rotate, subject, ip_address}, _from, state) do
    case do_rotate() do
      {:ok, new_key} ->
        audit_rotate(state.active, new_key, subject, ip_address)
        {:reply, {:ok, new_key.kid}, %{active: new_key, grace: load_grace()}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  # ── Sign / Verify ──────────────────────────────────────────────

  defp do_sign(%SigningKey{} = key, claims, opts) do
    now = System.system_time(:second)
    expires_in = Keyword.get(opts, :expires_in, 300)

    full =
      claims
      |> Map.put_new("iat", now)
      |> Map.put_new("exp", now + expires_in)

    jwk = JOSE.JWK.from_pem(key.private_pem)
    header = %{"alg" => "RS256", "kid" => key.kid, "typ" => "JWT"}

    {_, compact} =
      JOSE.JWT.sign(jwk, header, full)
      |> JOSE.JWS.compact()

    {:ok, compact}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp do_verify(compact, keys) do
    # JOSE.JWT.verify_strict matches by kid against the provided keys.
    # We pass both active + grace so a token signed just before
    # rotation still verifies.
    pubs = Enum.map(keys, &JOSE.JWK.from_pem(&1.public_pem))

    Enum.find_value(pubs, {:error, :no_matching_key}, fn jwk ->
      case JOSE.JWT.verify(jwk, compact) do
        {true, %JOSE.JWT{fields: claims}, _jws} ->
          case Map.get(claims, "exp") do
            nil -> {:ok, claims}
            exp when is_integer(exp) ->
              if exp >= System.system_time(:second),
                do: {:ok, claims},
                else: {:error, :expired}

            _ -> {:error, :invalid_exp}
          end

        _ ->
          nil
      end
    end)
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── DB helpers ─────────────────────────────────────────────────

  defp load_active do
    from(k in SigningKey, where: k.active == true, limit: 1)
    |> Repo.one()
  end

  defp load_grace do
    from(k in SigningKey,
      where: k.active == false and not is_nil(k.rotated_at),
      order_by: [desc: k.rotated_at],
      limit: ^@grace_size
    )
    |> Repo.all()
  end

  defp generate_and_insert(active?: active) do
    %{private_pem: priv, public_pem: pub} = generate_rsa_keypair()
    kid = Ecto.UUID.generate()

    %SigningKey{}
    |> Ecto.Changeset.cast(
      %{
        kid: kid,
        algorithm: "RS256",
        private_pem: priv,
        public_pem: pub,
        active: active
      },
      [:kid, :algorithm, :private_pem, :public_pem, :active]
    )
    |> Ecto.Changeset.unique_constraint(:kid)
    |> Repo.insert()
  end

  defp generate_rsa_keypair do
    jwk = JOSE.JWK.generate_key({:rsa, @rsa_bits})
    {_, private_pem} = JOSE.JWK.to_pem(jwk)
    {_, public_pem} = JOSE.JWK.to_public(jwk) |> JOSE.JWK.to_pem()
    %{private_pem: private_pem, public_pem: public_pem}
  end

  defp do_rotate do
    Repo.transaction(fn ->
      # Deactivate current — the partial unique index forbids two
      # rows with active = true, so we must flip first.
      from(k in SigningKey, where: k.active == true)
      |> Repo.update_all(set: [active: false, rotated_at: DateTime.utc_now()])

      case generate_and_insert(active?: true) do
        {:ok, key}        -> key
        {:error, change}  -> Repo.rollback(change)
      end
    end)
  end

  # ── Public JWK projection ──────────────────────────────────────

  defp public_jwk(%SigningKey{} = key) do
    {_, map} = JOSE.JWK.from_pem(key.public_pem) |> JOSE.JWK.to_map()
    Map.merge(map, %{"kid" => key.kid, "alg" => key.algorithm, "use" => "sig"})
  end

  # ── Audit ──────────────────────────────────────────────────────

  defp audit_bootstrap(%SigningKey{kid: kid}) do
    AuditLogs.log("l7.signing_key.bootstrap",
      actor_id: nil,
      actor_email: "system",
      target_type: "l7_signing_key",
      target_id: kid,
      metadata: %{algorithm: "RS256", bits: @rsa_bits}
    )
  end

  defp audit_rotate(%SigningKey{kid: old_kid}, %SigningKey{kid: new_kid}, subject, ip_address) do
    {actor_id, actor_email} =
      case subject do
        %FzHttp.Auth.Subject{actor: {:user, %{id: id, email: email}}} -> {id, email}
        _ -> {nil, "system"}
      end

    AuditLogs.log("l7.signing_key.rotate",
      actor_id: actor_id,
      actor_email: actor_email,
      ip_address: ip_address,
      target_type: "l7_signing_key",
      target_id: new_kid,
      metadata: %{retired_kid: old_kid, new_kid: new_kid}
    )
  end
end
