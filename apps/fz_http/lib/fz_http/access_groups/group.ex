defmodule FzHttp.AccessGroups.Group do
  use FzHttp, :schema

  schema "access_groups" do
    field :name,        :string
    field :description, :string
    field :source,      Ecto.Enum, values: [:manual, :idp_sync, :system], default: :manual
    field :external_id, :string

    has_many :memberships,
      FzHttp.AccessGroups.Membership,
      on_delete: :delete_all

    many_to_many :users,
      FzHttp.Users.User,
      join_through: FzHttp.AccessGroups.Membership

    has_many :allowed_application_links,
      FzHttp.Applications.AllowedGroup,
      foreign_key: :group_id,
      on_delete: :delete_all

    many_to_many :allowed_applications,
      FzHttp.Applications.Application,
      join_through: FzHttp.Applications.AllowedGroup

    # Virtual field populated by preload-and-count helpers (admin UI).
    field :member_count, :integer, virtual: true

    timestamps()
  end
end
