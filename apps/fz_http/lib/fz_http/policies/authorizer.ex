defmodule FzHttp.Policies.Authorizer do
  use FzHttp.Auth.Authorizer
  alias FzHttp.Policies.Policy

  def manage_policies_permission, do: build(Policy, :manage)

  @impl FzHttp.Auth.Authorizer
  def list_permissions_for_role(:admin) do
    [
      manage_policies_permission()
    ]
  end

  def list_permissions_for_role(_) do
    []
  end

  @impl FzHttp.Auth.Authorizer
  def for_subject(queryable, %Subject{} = subject) when is_user(subject) do
    cond do
      has_permission?(subject, manage_policies_permission()) ->
        queryable
    end
  end
end
