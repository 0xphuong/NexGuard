defmodule FzHttp.Policies.PolicyRule.Changeset do
  use FzHttp, :changeset
  alias FzHttp.Policies.PolicyRule

  @exclusion_msg "destination overlaps with an existing rule in this policy"
  @port_range_msg "port is not within valid range"
  @port_type_msg "port_type must be specified with port_range"

  @fields ~w[policy_id action destination port_type port_range comment priority]a
  @port_based_fields ~w[port_type port_range]a
  @required_fields ~w[policy_id action destination priority]a

  def create_changeset(attrs) do
    update_changeset(%PolicyRule{}, attrs)
  end

  def update_changeset(rule, attrs) do
    fields =
      if FzHttp.Policies.port_rules_supported?() do
        @fields
      else
        @fields -- @port_based_fields
      end

    rule
    |> cast(attrs, fields)
    |> validate_required(@required_fields)
    |> validate_length(:comment, max: 200)
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 9999)
    |> validate_required_group(~w[port_range port_type]a)
    |> check_constraint(:port_range,
      message: @port_range_msg,
      name: :policy_rule_port_range_is_within_valid_values
    )
    |> check_constraint(:port_type,
      message: @port_type_msg,
      name: :policy_rule_port_range_needs_type
    )
    |> exclusion_constraint(:destination,
      message: @exclusion_msg,
      name: :policy_rule_dest_overlap_excl
    )
    |> exclusion_constraint(:destination,
      message: @exclusion_msg,
      name: :policy_rule_dest_overlap_excl_port
    )
    |> assoc_constraint(:policy)
  end
end
