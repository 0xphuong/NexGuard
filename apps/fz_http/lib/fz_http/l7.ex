defmodule FzHttp.L7 do
  @moduledoc """
  L7 ZTNA namespace utilities (ADR-010, L7-B Phase 5).

  Sub-modules under this namespace handle individual concerns:

    * `FzHttp.L7.JwtSigner` — RS256 key lifecycle + sign/verify
    * `FzHttp.L7.Identity`  — VPN-IP → identity payload
    * `FzHttp.L7.BundleBuilder` — debounced policy bundle compile
    * `FzHttp.L7.VipAllocator` — `10.99.0.0/16` allocation

  This module exposes one helper used by callers that mutate identity
  payload inputs (user role, access_scope, group memberships) — it
  fans out a single `{:identity_updated, vpn_ip}` event per active
  VPN IP for the affected user, so the proxy invalidates its 30 s
  identity cache only for the keys that actually changed.
  """

  alias FzHttp.{Repo, Users}
  alias Phoenix.PubSub

  @identity_topic "nexguard:l7:identity"

  # The IPv4 /16 reserved for L7 application virtual IPs (ADR-014).
  # Mirrored by `FzWall.CLI.Helpers.Tproxy`'s nft rule + the
  # `VipAllocator` subnet. If you ever change this, grep `10.99.0.0/16`
  # across the repo — there are at least three other call sites that
  # must move in lockstep (nft TPROXY rule, allocator bounds doc,
  # vip_allocator integer math).
  @vip_cidr "10.99.0.0/16"

  @doc "The IPv4 /16 reserved for L7 application virtual IPs."
  def vip_cidr, do: @vip_cidr

  @doc """
  Broadcasts `{:identity_updated, vpn_ip_string}` on
  `nexguard:l7:identity` once per active VPN IP (IPv4 + IPv6) attached
  to the user's devices. Silent no-op for users with no devices.

  Call after any mutation that changes the identity payload returned
  by `FzHttp.L7.Identity.lookup_by_vpn_ip/1` — role, access_scope, or
  group membership.
  """
  @spec broadcast_identity_change(Users.User.t()) :: :ok
  def broadcast_identity_change(%Users.User{} = user) do
    user
    |> Repo.preload(:devices)
    |> Map.get(:devices, [])
    |> Enum.flat_map(fn d -> [d.ipv4, d.ipv6] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn inet ->
      ip_str = FzHttp.Types.INET.to_string(inet)
      PubSub.broadcast(FzHttp.PubSub, @identity_topic, {:identity_updated, ip_str})
    end)
  end

  @doc "Subscribe the caller to identity-invalidation events."
  def subscribe_identity, do: PubSub.subscribe(FzHttp.PubSub, @identity_topic)
end
