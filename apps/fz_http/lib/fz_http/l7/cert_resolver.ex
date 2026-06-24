defmodule FzHttp.L7.CertResolver do
  @moduledoc """
  Pure function: given a hostname and a list of candidate certs (with
  their denormalised SAN list), pick the one that should be presented
  for that hostname. ADR-015.

  Same algorithm is implemented identically in the Go proxy at
  `proxy/internal/policy/cert_resolver.go` so admin UI preview, bundle
  compile, and runtime SNI lookup all agree on which cert covers
  which app.

  Specificity rules (highest score wins):

      exact hostname match    →  1000 + len(san)     # exact > any wildcard
      "*.<parent>" matches host  →  len("*." + parent)
      no match               →  skip

  Tie-break: highest `not_after` first — when two certs equally cover
  a hostname (typical during dual-provisioning at renewal), the
  newer-expiring cert wins so freshly-rotated material adopts apps
  automatically.

  This module never raises; it returns `nil` when nothing matches,
  letting callers (the resolver in BundleBuilder, the live preview
  in the app form) render a useful "no matching cert" message.
  """

  @type cert_like :: %{
          required(:sans) => [String.t()],
          optional(:not_after) => DateTime.t() | nil,
          optional(any()) => any()
        }

  @doc """
  Best-match resolver. `candidates` is anything with `:sans` and
  optionally `:not_after` (the schema struct, a bundle map, or a
  test fixture — all work).
  """
  @spec resolve(String.t(), [cert_like]) :: cert_like | nil
  def resolve(hostname, candidates) when is_binary(hostname) and is_list(candidates) do
    host = String.downcase(hostname)

    candidates
    |> Enum.map(fn cert -> {best_score(host, cert.sans || []), cert} end)
    |> Enum.reject(fn {score, _} -> is_nil(score) end)
    |> case do
      [] ->
        nil

      scored ->
        scored
        |> Enum.max_by(fn {score, cert} ->
          {score, datetime_to_unix(Map.get(cert, :not_after))}
        end)
        |> elem(1)
    end
  end

  def resolve(_, _), do: nil

  @doc """
  True if `hostname` matches at least one SAN in `cert`.

  Convenience for callers (changeset validations, UI badges) that
  only need a yes/no without computing scores.
  """
  @spec covers?(String.t(), cert_like) :: boolean()
  def covers?(hostname, %{sans: sans}) when is_binary(hostname) and is_list(sans) do
    host = String.downcase(hostname)
    Enum.any?(sans, &matches?(host, &1))
  end

  def covers?(_, _), do: false

  @doc """
  Pluck only the certs that cover the hostname, sorted by
  specificity-then-recency. Useful for UI dropdowns that show
  "all candidates" with the best one preselected.
  """
  @spec candidates(String.t(), [cert_like]) :: [cert_like]
  def candidates(hostname, certs) when is_binary(hostname) and is_list(certs) do
    host = String.downcase(hostname)

    certs
    |> Enum.map(fn cert -> {best_score(host, cert.sans || []), cert} end)
    |> Enum.reject(fn {score, _} -> is_nil(score) end)
    |> Enum.sort_by(
      fn {score, cert} -> {score, datetime_to_unix(Map.get(cert, :not_after))} end,
      :desc
    )
    |> Enum.map(&elem(&1, 1))
  end

  # ── internals ──────────────────────────────────────────────────

  # Highest score across SANs (or nil if no SAN matches).
  defp best_score(host, sans) do
    sans
    |> Enum.map(&score(host, String.downcase(&1)))
    |> Enum.reject(&is_nil/1)
    |> case do
      []     -> nil
      scores -> Enum.max(scores)
    end
  end

  # Single-SAN scorer. `nil` = no match.
  defp score(host, host), do: 1000 + String.length(host)

  defp score(host, "*." <> parent) do
    case String.split(host, ".", parts: 2) do
      [_label, ^parent] -> String.length(parent) + 2
      _                 -> nil
    end
  end

  defp score(_, _), do: nil

  defp matches?(host, san) do
    not is_nil(score(host, String.downcase(san)))
  end

  # Treat missing not_after as oldest. Real certs always have one;
  # this is just defensive for hand-crafted test fixtures.
  defp datetime_to_unix(nil), do: 0
  defp datetime_to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp datetime_to_unix(_), do: 0

end
