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

    belongs_to :policy, FzHttp.Policies.Policy

    timestamps()
  end
end
