defmodule FzHttp.Applications.AllowedGroup do
  use FzHttp, :schema

  @primary_key false
  # Composite PK enforced in DB via migration; flags below let Ecto
  # identify rows by (application_id, group_id).
  schema "application_allowed_groups" do
    belongs_to :application, FzHttp.Applications.Application, primary_key: true
    belongs_to :group,       FzHttp.AccessGroups.Group,       primary_key: true
  end
end
