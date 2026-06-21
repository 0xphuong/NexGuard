defmodule FzHttp.ApplicationsFixtures do
  alias FzHttp.{Applications, Repo}
  alias FzHttp.Applications.Application
  alias FzHttp.{SubjectFixtures, UsersFixtures}
  alias FzHttp.L7.VipAllocator

  def application_attrs(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Enum.into(attrs, %{
      "name"        => "Fixture App #{n}",
      "description" => "fixture",
      "hostname"    => "app-#{n}.fixture.local",
      "backend"     => "https://10.0.50.#{rem(n, 250) + 1}",
      "cert_source" => :step_ca,
      "tls_mode"    => :terminate,
      "l7_rules"    => [],
      "enabled"     => false
    })
  end

  @doc """
  Insert directly via Repo with a freshly-allocated VIP. Uses
  `step_ca` cert source so the fixture doesn't need a real PEM.
  """
  def create_application(attrs \\ %{}) do
    {:ok, app} =
      Repo.transaction(fn ->
        vip = VipAllocator.allocate_inside_transaction()

        attrs =
          attrs
          |> application_attrs()
          |> Map.put("virtual_ip", vip)

        case attrs |> Application.Changeset.create_changeset() |> Repo.insert() do
          {:ok, app} -> app
          {:error, cs} -> Repo.rollback(cs)
        end
      end)

    app
  end

  @doc """
  Create via the context with an admin subject — exercises VIP
  allocation + PubSub broadcast + audit log.
  """
  def create_application_via_context(attrs \\ %{}) do
    subject = SubjectFixtures.create_subject(admin())
    {:ok, app} = Applications.create_application(application_attrs(attrs), subject)
    app
  end

  defp admin, do: UsersFixtures.create_user_with_role(:admin)
end
