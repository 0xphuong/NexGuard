defmodule FzHttp.OrgSettings.Settings do
  use FzHttp, :schema

  @primary_key {:id, :integer, autogenerate: false}
  # Single-row schema. The migration enforces `id = 1` via CHECK and
  # seeds the row at creation time, so `FzHttp.OrgSettings.get/0`
  # never needs nil-handling.
  schema "org_settings" do
    field :l7_enabled, :boolean, default: false
    timestamps()
  end
end
