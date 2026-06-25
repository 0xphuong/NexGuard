defmodule FzHttp.OrgSettings.Settings.Changeset do
  use FzHttp, :changeset
  alias FzHttp.OrgSettings.Settings

  # Accept IPv4 (`10.0.235.250`), IPv6 (`2001:db8::1`), or DNS hostname
  # (`dns.example.com`). Bracketed-IPv6 (`[::1]:53`) + explicit port
  # variants aren't allowed yet — CoreDNS' forward plugin defaults to
  # :53 and admins should keep it that way; revisit if we ever need
  # custom port.
  @host_or_ip ~r{^(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9a-f:]+|[a-z0-9][a-z0-9.\-]*\.[a-z]{2,})$}i

  @doc """
  Update the single-row org_settings record. `id` is immutable
  (singleton enforced by DB CHECK); only the editable fields change.
  """
  def update_changeset(%Settings{} = settings, attrs) do
    settings
    |> cast(attrs, [:l7_enabled, :coredns_forward_to, :coredns_forward_to_fallback])
    |> validate_required([:l7_enabled])
    |> normalize_server_list(:coredns_forward_to)
    |> normalize_server_list(:coredns_forward_to_fallback)
    |> validate_server_list(:coredns_forward_to)
    |> validate_server_list(:coredns_forward_to_fallback)
  end

  # ── Normalize ───────────────────────────────────────────────────

  # Accept the field either as a list (from API/tests) OR as a single
  # comma-separated string (from the admin form, where the textbox is
  # one input). Split on commas/whitespace, trim, drop empties, dedupe
  # while preserving order — the order is meaningful (CoreDNS tries
  # them sequentially).
  defp normalize_server_list(changeset, field) do
    case get_change(changeset, field) do
      nil -> changeset

      value ->
        normalized =
          value
          |> to_list()
          |> Enum.flat_map(&String.split(&1, [",", "\n", "\r", " ", "\t"], trim: true))
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        put_change(changeset, field, normalized)
    end
  end

  defp to_list(v) when is_list(v),   do: v
  defp to_list(v) when is_binary(v), do: [v]
  defp to_list(_),                    do: []

  # ── Validate ────────────────────────────────────────────────────

  defp validate_server_list(changeset, field) do
    list = get_field(changeset, field) || []

    invalid = Enum.reject(list, &valid_server?/1)

    cond do
      field == :coredns_forward_to and list == [] ->
        # Primary is required — empty would generate a Corefile with
        # `forward .` and no upstream, which CoreDNS refuses to load.
        add_error(changeset, field, "primary DNS upstream is required (at least one entry)")

      invalid != [] ->
        add_error(changeset, field,
          "invalid entries: #{Enum.join(invalid, ", ")} — must be IPv4, IPv6, or hostname")

      true ->
        changeset
    end
  end

  defp valid_server?(s) when is_binary(s) do
    String.length(s) in 1..253 and Regex.match?(@host_or_ip, s)
  end

  defp valid_server?(_), do: false
end
