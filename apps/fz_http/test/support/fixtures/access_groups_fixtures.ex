defmodule FzHttp.AccessGroupsFixtures do
  alias FzHttp.{AccessGroups, Repo}
  alias FzHttp.AccessGroups.Group
  alias FzHttp.{SubjectFixtures, UsersFixtures}

  def group_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "group-#{System.unique_integer([:positive])}",
      description: "fixture group",
      source: :manual
    })
  end

  @doc """
  Insert a group directly via Repo (bypasses Auth) — fixture helper
  for tests that don't care about the permission path.
  """
  def create_group(attrs \\ %{}) do
    attrs = group_attrs(attrs)

    {:ok, group} =
      attrs
      |> Group.Changeset.create_changeset()
      |> Repo.insert()

    group
  end

  @doc """
  Same but goes through the context with an admin subject — exercises
  the full permission + audit path.
  """
  def create_group_via_context(attrs \\ %{}) do
    subject = SubjectFixtures.create_subject(admin())
    {:ok, group} = AccessGroups.create_group(group_attrs(attrs), subject)
    group
  end

  defp admin do
    UsersFixtures.create_user_with_role(:admin)
  end
end
