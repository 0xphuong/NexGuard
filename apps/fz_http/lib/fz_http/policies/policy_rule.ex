defmodule FzHttp.Policies.PolicyRule do
  use FzHttp, :schema

  schema "policy_rules" do
    # Shape identical to `FzHttp.Rules.Rule` minus the `belongs_to :user`.
    # Kept intentionally 1:1 so `FzHttp.Policies.as_effective_rules/0`
    # can emit projections that plug into the exact same
    # `%{destination, action, port_type, port_range, user_id}` map
    # `FzWall.Server` already consumes.
    field :action, Ecto.Enum, values: [:drop, :accept], default: :accept
    field :destination, FzHttp.Types.INET
    field :port_type, Ecto.Enum, values: [:tcp, :udp]
    field :port_range, FzHttp.Types.Int4Range
    # v4.0.2: admin-facing memo, surfaced in the rules table so
    # the business reason shows next to each destination. Not
    # passed to fz_wall -- it's a UI-only column.
    field :comment, :string
    # v4.1.0: explicit ordering. Lower = evaluated first, matching
    # iptables sequence-number / AWS NACL / GCP firewall priority.
    # Ties broken by `inserted_at ASC` inside the effective-rules
    # sort. Default 100 leaves headroom on both sides (0..99 for
    # "priority overrides" like drop-specific-before-broad-allow,
    # 101..9999 for "catch-all" like Default deny 0.0.0.0/0 last).
    field :priority, :integer, default: 100

    belongs_to :policy, FzHttp.Policies.Policy

    timestamps()
  end
end
