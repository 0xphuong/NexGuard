defmodule FzHttp.L7.VipAllocator do
  @moduledoc """
  Allocates virtual IPs in the L7 VIP subnet (`10.99.0.0/16`, ADR-014)
  for managed applications. Each application gets a unique VIP; the
  L7 proxy looks up `original_dst → application` from this mapping.

  Allocation is **monotonic by first-free scan**: we pick the lowest
  offset that isn't already in `applications.virtual_ip`. Deleted
  VIPs are reusable. A Postgres advisory lock serialises concurrent
  allocations so two simultaneous admin "create app" requests can't
  pick the same VIP.

  Range:
    * First usable: `10.99.0.1`  (offset 1)
    * Last  usable: `10.99.255.254` (offset 65534)
    * Skipped: `10.99.0.0` (network) and `10.99.255.255` (broadcast)

  The subnet is hard-coded — it must stay aligned with both the
  nftables TPROXY rule (`fz_wall`) and the changeset validator in
  `FzHttp.Applications.Application.Changeset`. If this ever needs to
  change, search for `10.99.0.0/16` across the repo.
  """

  alias FzHttp.Repo
  import Ecto.Query

  @first_offset 1
  @last_offset  65_534
  # Lock namespace — `hashtext('vip_allocator')`. Stable across deploys.
  @lock_name "vip_allocator"

  @typedoc "An IPv4 address allocated inside `10.99.0.0/16`."
  @type vip :: Postgrex.INET.t()

  @doc """
  Allocate the next free VIP. Returns `{:ok, %Postgrex.INET{}}` or
  `{:error, :exhausted}` when every offset is in use.

  Must run inside a Repo transaction OR be allowed to start its own
  (the function wraps `Repo.transaction/1` to ensure the advisory
  lock is held for the lifetime of the SELECT-then-INSERT it
  precedes — the caller is expected to INSERT the application row
  inside the same transaction so the lock spans both queries).
  """
  @spec allocate() :: {:ok, vip} | {:error, :exhausted | term()}
  def allocate do
    Repo.transaction(fn ->
      acquire_lock()
      case first_free_offset() do
        nil    -> Repo.rollback(:exhausted)
        offset -> offset_to_inet(offset)
      end
    end)
  end

  @doc """
  Same as `allocate/0` but assumes the caller already opened a
  transaction. Used by `FzHttp.Applications.create/2` which needs
  the lock to span allocation + INSERT.
  """
  @spec allocate_inside_transaction() :: vip
  def allocate_inside_transaction do
    acquire_lock()
    case first_free_offset() do
      nil    -> raise "VIP subnet exhausted (10.99.0.0/16 — 65,534 slots used)"
      offset -> offset_to_inet(offset)
    end
  end

  # ── internals ───────────────────────────────────────────────────

  defp acquire_lock do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [@lock_name])
  end

  defp first_free_offset do
    used = used_offsets()
    Enum.find(@first_offset..@last_offset, fn offset ->
      not MapSet.member?(used, offset)
    end)
  end

  defp used_offsets do
    from(a in "applications", select: a.virtual_ip)
    |> Repo.all()
    |> Enum.reduce(MapSet.new(), fn inet, acc ->
      case ip_to_offset(inet) do
        nil      -> acc
        offset   -> MapSet.put(acc, offset)
      end
    end)
  end

  # Convert `10.99.c.d` IPv4 → integer offset within the /16. Returns
  # nil for any address outside the subnet (defensive — shouldn't
  # happen because the changeset validates inclusion).
  defp ip_to_offset(%Postgrex.INET{address: {10, 99, c, d}}), do: c * 256 + d
  defp ip_to_offset(_), do: nil

  defp offset_to_inet(offset) do
    c = div(offset, 256)
    d = rem(offset, 256)
    %Postgrex.INET{address: {10, 99, c, d}, netmask: 32}
  end
end
