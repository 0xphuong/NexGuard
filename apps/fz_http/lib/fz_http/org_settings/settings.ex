defmodule FzHttp.OrgSettings.Settings do
  use FzHttp, :schema

  @primary_key {:id, :integer, autogenerate: false}
  # Single-row schema. The migration enforces `id = 1` via CHECK and
  # seeds the row at creation time, so `FzHttp.OrgSettings.get/0`
  # never needs nil-handling.
  schema "org_settings" do
    field :l7_enabled, :boolean, default: false

    # CoreDNS forward configuration (admin-editable via /settings/l7).
    # `coredns_forward_to` is the primary list; `_fallback` is appended
    # after it in the generated Corefile so CoreDNS' `policy sequential`
    # treats it as "try after every primary failed".
    field :coredns_forward_to,          {:array, :string}, default: []
    field :coredns_forward_to_fallback, {:array, :string}, default: []

    timestamps()
  end
end
