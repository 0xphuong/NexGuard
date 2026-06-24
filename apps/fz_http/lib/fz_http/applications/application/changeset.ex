defmodule FzHttp.Applications.Application.Changeset do
  use FzHttp, :changeset
  alias FzHttp.Applications.Application
  alias FzHttp.L7.{CertResolver, TlsCertificate}
  alias FzHttp.Repo

  # RFC 1035: labels 1-63 chars, alphanumeric+hyphen, no leading/trailing
  # hyphen, dot-separated. Total length ≤ 253. Lower-cased on input.
  @hostname_regex ~r/^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/

  # VIP subnet — must stay aligned with ADR-014 + nftables TPROXY rule.
  @vip_network %Postgrex.INET{address: {10, 99, 0, 0}, netmask: 16}

  @permitted_create ~w[
    name description
    hostname virtual_ip backend
    cert_source cert_pem key_pem
    tls_cert_id tls_auto_match
    tls_mode l7_rules enabled
  ]a

  # Explicit, NOT `@permitted_create -- [...]`. The subtraction
  # pattern relied on a reader to spot `[:virtual_ip]` and quietly
  # ALSO let `:enabled` through — which bypassed
  # `validate_required_for_enable/1` (the rules + cert gate that's
  # ONLY run by `set_enabled_changeset/2`). A malicious / mis-typed
  # `update_application(app, %{"enabled" => true})` could flip an
  # under-configured app live. Keep `:enabled` out of this list;
  # callers MUST go through `Applications.set_application_enabled/4`.
  @permitted_update ~w[
    name description
    hostname backend
    cert_source cert_pem key_pem
    tls_cert_id tls_auto_match
    tls_mode l7_rules
  ]a

  @required_create ~w[name hostname virtual_ip backend cert_source]a
  @required_update ~w[name hostname backend cert_source]a

  @doc """
  Create changeset — used by admin app declaration form.
  """
  def create_changeset(attrs) do
    %Application{}
    |> cast(attrs, @permitted_create)
    |> validate_required(@required_create)
    |> normalize_hostname()
    |> validate_format(:hostname, @hostname_regex,
         message: "must be a valid DNS hostname (lower-case, labels separated by dots)")
    |> validate_length(:name,        min: 2,  max: 100)
    |> validate_length(:description,         max: 500)
    |> validate_length(:backend,     min: 8,  max: 500)
    |> validate_format(:backend, ~r{^https?://},
         message: "must begin with http:// or https://")
    |> validate_vip_in_subnet()
    |> validate_tls_mode_compat()
    |> validate_cert_consistency()
    |> validate_l7_rules()
    |> unique_constraint(:hostname)
    |> unique_constraint(:virtual_ip)
  end

  @doc """
  Update changeset.

  Two fields are deliberately NOT in `@permitted_update`:

    * `virtual_ip` — immutable post-creation. Changing it would orphan
      in-flight connections and invalidate the proxy bundle cache. To
      change a VIP, delete and re-create the app.

    * `enabled` — must go through `set_enabled_changeset/2` so the
      rules-present + cert-present guards run. See the comment above
      `@permitted_update` for the bypass we're closing.
  """
  def update_changeset(%Application{} = app, attrs) do
    app
    |> cast(attrs, @permitted_update)
    |> validate_required(@required_update)
    |> normalize_hostname()
    |> validate_format(:hostname, @hostname_regex,
         message: "must be a valid DNS hostname")
    |> validate_length(:name,        min: 2,  max: 100)
    |> validate_length(:backend,     min: 8,  max: 500)
    |> validate_format(:backend, ~r{^https?://})
    |> validate_tls_mode_compat()
    |> validate_cert_consistency()
    |> validate_l7_rules()
    |> unique_constraint(:hostname)
  end

  @doc """
  Toggle-only changeset — Enable/Disable button in admin UI. Refuses
  to enable an app that's not fully configured (cert missing, no
  rules, etc.). Returns the unchanged struct on a no-op.
  """
  def set_enabled_changeset(%Application{} = app, true) do
    app
    |> change(enabled: true)
    |> validate_cert_consistency()
    |> validate_l7_rules()
    |> validate_required_for_enable()
  end

  def set_enabled_changeset(%Application{} = app, false) do
    change(app, enabled: false)
  end

  # ── internal helpers ────────────────────────────────────────────

  defp normalize_hostname(changeset) do
    case get_change(changeset, :hostname) do
      nil -> changeset
      v   -> put_change(changeset, :hostname, String.downcase(String.trim(v)))
    end
  end

  defp validate_vip_in_subnet(changeset) do
    validate_change(changeset, :virtual_ip, fn :virtual_ip, ip ->
      if ip_in_network?(ip, @vip_network) do
        []
      else
        [virtual_ip: "must be inside 10.99.0.0/16"]
      end
    end)
  end

  # passthrough TLS isn't implemented in v1 — gate it at the changeset
  # so admin UI returns a friendly error instead of "TLS mode" appearing
  # to accept it. Remove this validator when L7 v2 adds passthrough.
  defp validate_tls_mode_compat(changeset) do
    case get_field(changeset, :tls_mode) do
      :passthrough -> add_error(changeset, :tls_mode, "passthrough is reserved for v2 — choose terminate")
      _            -> changeset
    end
  end

  # Cert-source-specific validation:
  #
  #   :upload  — both `cert_pem` and `key_pem` required + SAN must
  #              cover hostname (per-app PEM, legacy path).
  #
  #   :step_ca — proxy/step-ca pipeline issues cert at runtime;
  #              admin must NOT paste one, otherwise we'd ambiguously
  #              hold two cert sources.
  #
  #   :library — `tls_cert_id` must be set OR `tls_auto_match = true`
  #              AND the library has at least one cert covering
  #              `hostname`. Per-app `cert_pem`/`key_pem` must be
  #              blank (the cert lives on `tls_certificates`).
  defp validate_cert_consistency(changeset) do
    case get_field(changeset, :cert_source) do
      :upload ->
        changeset
        |> validate_required([:cert_pem, :key_pem])
        |> validate_cert_matches_hostname()

      :step_ca ->
        changeset
        |> validate_cert_field_empty(:cert_pem)
        |> validate_cert_field_empty(:key_pem)

      :library ->
        changeset
        |> validate_cert_field_empty(:cert_pem)
        |> validate_cert_field_empty(:key_pem)
        |> validate_library_reference()

      _ -> changeset
    end
  end

  # `:library` path: either an explicit FK is set (admin picked a cert
  # from the library), OR auto-match is on AND some library cert
  # actually covers the hostname. Anything else is a save-time error.
  defp validate_library_reference(changeset) do
    tls_cert_id    = get_field(changeset, :tls_cert_id)
    auto_match     = get_field(changeset, :tls_auto_match)
    hostname       = get_field(changeset, :hostname)

    cond do
      not is_nil(tls_cert_id) ->
        validate_pinned_cert_covers_hostname(changeset, tls_cert_id, hostname)

      auto_match == true and is_binary(hostname) ->
        validate_auto_match_has_candidate(changeset, hostname)

      true ->
        add_error(changeset, :tls_cert_id,
          "pick a certificate from the library or enable auto-match")
    end
  end

  defp validate_pinned_cert_covers_hostname(changeset, tls_cert_id, hostname)
       when is_binary(hostname) do
    case Repo.get(TlsCertificate, tls_cert_id) do
      nil ->
        add_error(changeset, :tls_cert_id, "selected certificate no longer exists")

      %TlsCertificate{} = cert ->
        if CertResolver.covers?(hostname, cert) do
          changeset
        else
          add_error(changeset, :tls_cert_id,
            "selected certificate (#{cert.primary_san}) does not cover #{hostname}")
        end
    end
  end

  defp validate_pinned_cert_covers_hostname(changeset, _id, _no_host), do: changeset

  defp validate_auto_match_has_candidate(changeset, hostname) do
    certs = Repo.all(TlsCertificate)

    case CertResolver.resolve(hostname, certs) do
      nil ->
        add_error(changeset, :tls_auto_match,
          "no certificate in the library covers #{hostname} — upload one or pick explicitly")

      _cert ->
        changeset
    end
  end

  defp validate_cert_field_empty(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      ""  -> changeset
      _   -> add_error(changeset, field, "must be blank when cert_source = step_ca")
    end
  end

  defp validate_cert_matches_hostname(changeset) do
    with cert_pem when is_binary(cert_pem) <- get_field(changeset, :cert_pem),
         hostname when is_binary(hostname) <- get_field(changeset, :hostname) do
      case parse_cert_subject_names(cert_pem) do
        {:ok, names} ->
          if hostname_matches_any?(hostname, names),
            do: changeset,
            else: add_error(changeset, :cert_pem,
                   "cert does not cover hostname #{hostname} (cert SAN/CN: #{Enum.join(names, ", ")})")

        {:error, reason} ->
          add_error(changeset, :cert_pem, "could not parse: #{reason}")
      end
    else
      _ -> changeset
    end
  end

  defp parse_cert_subject_names(cert_pem) do
    try do
      cert = X509.Certificate.from_pem!(cert_pem)
      names = X509.Certificate.extension(cert, :subject_alt_name) |> sans_to_strings()
      cn    = X509.Certificate.subject(cert) |> common_name()
      {:ok, Enum.uniq([cn | names]) |> Enum.reject(&is_nil/1)}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp sans_to_strings(nil), do: []
  defp sans_to_strings(extension) do
    {:Extension, _, _, sans} = extension
    Enum.flat_map(sans, fn
      {:dNSName, charlist} -> [to_string(charlist)]
      _                    -> []
    end)
  end

  defp common_name({:rdnSequence, rdns}) do
    Enum.find_value(rdns, fn rdn ->
      Enum.find_value(rdn, fn
        {:AttributeTypeAndValue, {2, 5, 4, 3}, {_, name}} -> to_string(name)
        _                                                  -> nil
      end)
    end)
  end

  # Allow exact match or single-label wildcard (`*.example.com`).
  defp hostname_matches_any?(hostname, names) do
    Enum.any?(names, fn n ->
      n = String.downcase(n)
      cond do
        n == hostname                             -> true
        String.starts_with?(n, "*.")             ->
          suffix = String.replace_prefix(n, "*.", "")
          host_parent =
            hostname |> String.split(".", parts: 2) |> List.last() |> to_string()
          suffix == host_parent
        true                                      -> false
      end
    end)
  end

  defp validate_l7_rules(changeset) do
    case get_field(changeset, :l7_rules) do
      nil   -> changeset
      []    -> changeset
      rules when is_list(rules) ->
        rules
        |> Enum.with_index()
        |> Enum.reduce(changeset, fn {rule, idx}, cs -> validate_rule(cs, rule, idx) end)

      _ -> add_error(changeset, :l7_rules, "must be a JSON array")
    end
  end

  defp validate_rule(cs, rule, idx) when is_map(rule) do
    cond do
      not is_binary(rule["action"]) or rule["action"] not in ["allow", "deny"] ->
        add_error(cs, :l7_rules, "rule ##{idx}: action must be \"allow\" or \"deny\"")

      Map.has_key?(rule, "method") and not list_of_strings?(rule["method"]) ->
        add_error(cs, :l7_rules, "rule ##{idx}: method must be a list of strings")

      Map.has_key?(rule, "path_prefix") and not is_binary(rule["path_prefix"]) ->
        add_error(cs, :l7_rules, "rule ##{idx}: path_prefix must be a string")

      Map.has_key?(rule, "require_groups") and not list_of_strings?(rule["require_groups"]) ->
        add_error(cs, :l7_rules, "rule ##{idx}: require_groups must be a list of strings")

      Map.has_key?(rule, "require_mfa_age_seconds") and not is_integer(rule["require_mfa_age_seconds"]) ->
        add_error(cs, :l7_rules, "rule ##{idx}: require_mfa_age_seconds must be an integer")

      true -> cs
    end
  end

  defp validate_rule(cs, _, idx),
    do: add_error(cs, :l7_rules, "rule ##{idx}: must be a JSON object")

  defp list_of_strings?(list) when is_list(list),
    do: Enum.all?(list, &is_binary/1)
  defp list_of_strings?(_), do: false

  defp validate_required_for_enable(changeset) do
    # Pull fields into bindings BEFORE the cond — Elixir's cond
    # clause heads are single boolean expressions and don't accept
    # `var = expr; condition` sequences.
    rules       = get_field(changeset, :l7_rules) || []
    cert_source = get_field(changeset, :cert_source)
    cert_pem    = get_field(changeset, :cert_pem)
    tls_cert_id = get_field(changeset, :tls_cert_id)
    auto_match  = get_field(changeset, :tls_auto_match)
    hostname    = get_field(changeset, :hostname)

    cond do
      rules == [] ->
        add_error(changeset, :enabled, "cannot enable without at least one L7 rule")

      cert_source == :upload and is_nil(cert_pem) ->
        add_error(changeset, :enabled, "cannot enable without an uploaded certificate")

      cert_source == :library and is_nil(tls_cert_id) and
          not (auto_match == true and library_can_serve?(hostname)) ->
        add_error(changeset, :enabled,
          "cannot enable without a library cert covering #{hostname}")

      true ->
        changeset
    end
  end

  defp library_can_serve?(nil), do: false

  defp library_can_serve?(hostname) when is_binary(hostname) do
    not is_nil(CertResolver.resolve(hostname, Repo.all(TlsCertificate)))
  end

  defp ip_in_network?(%Postgrex.INET{address: {a, b, _, _}}, %Postgrex.INET{
         address: {na, nb, _, _},
         netmask: 16
       })
       when a == na and b == nb,
       do: true

  defp ip_in_network?(_, _), do: false
end
