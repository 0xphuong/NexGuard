defmodule FzHttp.Applications.Authorizer do
  use FzHttp.Auth.Authorizer
  import Ecto.Query
  alias FzHttp.Applications.Application

  def view_applications_permission,   do: build(Application, :view)
  def manage_applications_permission, do: build(Application, :manage)
  # Reserved: per-app group/rule edit may eventually be a separate
  # permission for finer-grained delegation. For now, an admin who
  # can manage one app can manage all.
  def manage_l7_policy_permission,    do: build(Application, :manage_l7_policy)

  @impl FzHttp.Auth.Authorizer
  def list_permissions_for_role(:admin) do
    [
      view_applications_permission(),
      manage_applications_permission(),
      manage_l7_policy_permission()
    ]
  end

  def list_permissions_for_role(:unprivileged), do: []
  def list_permissions_for_role(_),             do: []

  @impl FzHttp.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) when is_user(subject) do
    if has_permission?(subject, view_applications_permission()) do
      queryable
    else
      from(a in queryable, where: false)
    end
  end
end
