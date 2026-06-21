defmodule FzHttp.L7.Identity do
  @moduledoc """
  Resolves a VPN-IP (assigned to a WireGuard device) into the identity
  payload that the L7 proxy uses to authorize per-app access (ADR-010).

  Fail-closed: any ambiguity (unparseable IP, no matching device,
  multi-match — implies data corruption — or a disabled user) maps to
  `:not_found` so the proxy denies and forces re-auth.

  Caller contract: returns either

      {:ok, identity_map, %{user_updated_at: dt}}

  where the third element carries the cache key for ETag computation
  in the HTTP layer (kept out of the identity payload itself so the
  wire format remains a strict projection of public fields), or

      :not_found.
  """

  import Ecto.Query

  alias FzHttp.Auth.MFA
  alias FzHttp.Devices.Device
  alias FzHttp.Repo
  alias FzHttp.Types
  alias FzHttp.Users.User

  @type identity :: %{
          user_id: Ecto.UUID.t(),
          email: String.t(),
          role: atom(),
          access_scope: atom(),
          groups: [String.t()],
          device_id: Ecto.UUID.t(),
          mfa_age_seconds: non_neg_integer() | nil,
          signed_in_at: DateTime.t() | nil
        }

  @spec lookup_by_vpn_ip(String.t()) :: {:ok, identity, %{user_updated_at: DateTime.t()}} | :not_found
  def lookup_by_vpn_ip(ip) when is_binary(ip) do
    with {:ok, inet} <- cast_ip(ip),
         [%Device{user: %User{disabled_at: nil} = user} = device] <- find_devices(inet) do
      identity = build_identity(device, user)
      {:ok, identity, %{user_updated_at: user.updated_at}}
    else
      _ -> :not_found
    end
  end

  defp cast_ip(ip) do
    case Types.IP.cast(ip) do
      {:ok, %Postgrex.INET{} = inet} -> {:ok, inet}
      _ -> :error
    end
  end

  # ipv4 OR ipv6 match — a single device row may carry both, but they
  # come from a shared sequence so no two rows ever share the same IP.
  # If the query returns multiple rows we treat it as data corruption
  # and refuse to resolve (the `with` clause above falls through).
  defp find_devices(%Postgrex.INET{} = inet) do
    from(d in Device,
      where: d.ipv4 == ^inet or d.ipv6 == ^inet,
      preload: [user: :groups]
    )
    |> Repo.all()
  end

  defp build_identity(%Device{} = device, %User{} = user) do
    %{
      user_id: user.id,
      email: user.email,
      role: user.role,
      access_scope: user.access_scope,
      groups: Enum.map(user.groups, & &1.name),
      device_id: device.id,
      mfa_age_seconds: mfa_age_seconds(user),
      signed_in_at: user.last_signed_in_at
    }
  end

  # `last_signed_in_at` is stamped at MFA completion when MFA is on the
  # account (see the VPN MFA session-enforcement change). If the user
  # has NO MFA method configured, the same timestamp reflects only the
  # password step — return nil so the proxy doesn't mistake it for MFA
  # freshness.
  defp mfa_age_seconds(%User{last_signed_in_at: nil}), do: nil

  defp mfa_age_seconds(%User{last_signed_in_at: ts} = user) do
    if user_has_mfa?(user) do
      DateTime.diff(DateTime.utc_now(), ts, :second)
    else
      nil
    end
  end

  defp user_has_mfa?(%User{id: id}) do
    Repo.exists?(from(m in MFA.Method, where: m.user_id == ^id))
  end
end
