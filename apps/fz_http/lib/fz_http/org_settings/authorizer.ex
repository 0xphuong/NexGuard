defmodule FzHttp.OrgSettings.Authorizer do
  use FzHttp.Auth.Authorizer
  alias FzHttp.OrgSettings.Settings

  def view_org_settings_permission,   do: build(Settings, :view)
  def manage_l7_settings_permission,  do: build(Settings, :manage_l7)

  @impl FzHttp.Auth.Authorizer
  def list_permissions_for_role(:admin) do
    [
      view_org_settings_permission(),
      manage_l7_settings_permission()
    ]
  end

  # Unprivileged users do not see org settings at all.
  def list_permissions_for_role(:unprivileged), do: []
  def list_permissions_for_role(_),             do: []

  @impl FzHttp.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) when is_user(subject) do
    if has_permission?(subject, view_org_settings_permission()) do
      queryable
    else
      from(s in queryable, where: false)
    end
  end
end
