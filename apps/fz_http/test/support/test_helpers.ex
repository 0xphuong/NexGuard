defmodule FzHttp.TestHelpers do
  @moduledoc """
  Test setup helpers
  """

  alias FzHttp.{
    ConnectivityChecksFixtures,
    DevicesFixtures,
    NotificationsFixtures,
    Repo,
    Users.User,
    UsersFixtures
  }

  def clear_users do
    Repo.delete_all(User)
  end

  def create_unprivileged_device(%{unprivileged_user: user}) do
    {:ok, device: DevicesFixtures.create_device(user: user)}
  end

  def create_device(tags) do
    device =
      if tags[:unauthed] || is_nil(tags[:user_id]) do
        DevicesFixtures.create_device()
      else
        DevicesFixtures.create_device(%{user_id: tags[:user_id]})
      end

    {:ok, device: device}
  end

  def create_other_user_device(_) do
    user = UsersFixtures.create_user_with_role(:unprivileged, %{email: "other_user@test"})

    device =
      DevicesFixtures.create_device(%{
        user: user,
        name: "other device"
      })

    {:ok, other_device: device}
  end

  def create_connectivity_checks(_tags) do
    connectivity_checks =
      Enum.map(1..5, fn _i ->
        ConnectivityChecksFixtures.create_connectivity_check()
      end)

    {:ok, connectivity_checks: connectivity_checks}
  end

  def create_devices(tags) do
    user =
      if tags[:unathed] || is_nil(tags[:user_id]) do
        UsersFixtures.create_user_with_role(:admin)
      else
        Repo.get!(User, tags[:user_id])
      end

    devices =
      Enum.map(1..5, fn num ->
        DevicesFixtures.create_device(%{
          name: "device #{num}",
          user: user
        })
      end)

    {:ok, devices: devices}
  end

  def create_user(tags) do
    role = tags[:role] || :admin
    user = UsersFixtures.create_user_with_role(role)

    {:ok, user: user}
  end

  # v4.0.0: `create_rule*` helpers removed with `FzHttp.Rules`.
  # Retained: `create_user_and_device/1` (used by device/user
  # notifier + events tests that previously included an
  # incidental rule they didn't actually assert on).
  def create_user_and_device(_) do
    user = UsersFixtures.create_user_with_role(:admin)

    device =
      DevicesFixtures.create_device(
        user: user,
        name: "device"
      )

    {:ok, user: user, device: device}
  end

  def create_user_with_valid_sign_in_token(_) do
    {:ok, user: %User{}} = UsersFixtures.create_user_with_role(:admin)
  end

  def create_user_with_expired_sign_in_token(_) do
    expired_at = DateTime.add(DateTime.utc_now(), -1 * 86_401)

    {:ok,
     user:
       UsersFixtures.create_user_with_role(:admin, %{
         sign_in_token: "EXPIRED_TOKEN",
         sign_in_token_created_at: expired_at
       })}
  end

  def create_users(tags) do
    count = tags[:count] || 5
    role = tags[:role] || :admin

    users =
      Enum.map(1..count, fn i ->
        UsersFixtures.create_user_with_role(role, %{email: "userlist#{i}@test"})
      end)

    {:ok, users: users}
  end

  def clear_users(_) do
    {count, _result} = Repo.delete_all(User)
    {:ok, count: count}
  end

  def create_notifications(opts \\ []) do
    count = opts[:count] || 5

    notifications =
      for i <- 1..count do
        NotificationsFixtures.notification_fixture(user: "test#{i}@localhost")
      end

    {:ok, notifications: notifications}
  end

  def create_notification(attrs \\ []) do
    {:ok, notification: NotificationsFixtures.notification_fixture(attrs)}
  end
end
