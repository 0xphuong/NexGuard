defmodule FzHttp.AccessGroups.Authorizer do
  use FzHttp.Auth.Authorizer
  alias FzHttp.AccessGroups.Group

  def view_access_groups_permission,    do: build(Group, :view)
  def manage_access_groups_permission,  do: build(Group, :manage)

  @impl FzHttp.Auth.Authorizer

  # Admins can view and manage all groups.
  def list_permissions_for_role(:admin) do
    [
      view_access_groups_permission(),
      manage_access_groups_permission()
    ]
  end

  # Unprivileged users have no visibility into the group catalog.
  # They learn their own group membership only via the bundle's
  # identity payload at the proxy — not via the admin API.
  def list_permissions_for_role(:unprivileged), do: []

  def list_permissions_for_role(_), do: []

  @impl FzHttp.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) when is_user(subject) do
    if has_permission?(subject, view_access_groups_permission()) do
      queryable
    else
      # Belt-and-suspenders: a defense-in-depth filter that returns the
      # empty set rather than raising. Real enforcement is on the
      # controller side via `ensure_has_permissions/2`.
      from(g in queryable, where: false)
    end
  end
end
