defmodule FzHttp.Users do
  alias FzHttp.{Repo, Auth, Validator, Config, Telemetry, AuditLogs}
  alias FzHttp.Users.{Authorizer, User}
  require Ecto.Query

  def count do
    User.Query.all()
    |> Repo.aggregate(:count)
  end

  def count_by_role(role) do
    User.Query.by_role(role)
    |> Repo.aggregate(:count)
  end

  def fetch_count_by_role(role, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_users_permission()) do
      User.Query.by_role(role)
      |> Authorizer.for_subject(subject)
      |> Repo.aggregate(:count)
    end
  end

  def fetch_user_by_id(id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_users_permission()) do
      fetch_user_by_id(id)
    end
  end

  def fetch_user_by_id(id) do
    if Validator.valid_uuid?(id) do
      User.Query.by_id(id)
      |> Repo.fetch()
    else
      {:error, :not_found}
    end
  end

  def fetch_user_by_id!(id) do
    User.Query.by_id(id)
    |> Repo.fetch!()
  end

  def fetch_user_by_email(email) do
    User.Query.by_email(email)
    |> Repo.fetch()
  end

  def fetch_user_by_id_or_email(id_or_email, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_users_permission()) do
      if Validator.valid_uuid?(id_or_email) do
        fetch_user_by_id(id_or_email)
      else
        fetch_user_by_email(id_or_email)
      end
    end
  end

  def list_users(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_users_permission()) do
      {hydrate, _opts} = Keyword.pop(opts, :hydrate, [])

      User.Query.all()
      |> hydrate_fields(hydrate)
      |> Repo.list()
    end
  end

  defp hydrate_fields(queryable, []), do: queryable

  defp hydrate_fields(queryable, [:device_count | rest]) do
    queryable
    |> User.Query.hydrate_device_count()
    |> hydrate_fields(rest)
  end

  # `:index` bundles every aggregate the admin /users page needs in
  # one query — device_count + last_handshake + mfa_count +
  # mfa_last_used. Use this instead of `:device_count` from the
  # index LiveView; LiveViews that only need device_count keep using
  # the single-purpose hydrate token.
  defp hydrate_fields(queryable, [:index | rest]) do
    queryable
    |> User.Query.hydrate_index()
    |> hydrate_fields(rest)
  end

  def request_sign_in_token(%User{} = user) do
    user
    |> User.Changeset.generate_sign_in_token()
    |> Repo.update()
  end

  def consume_sign_in_token(%User{sign_in_token_hash: nil}, _token) do
    {:error, :no_token}
  end

  def consume_sign_in_token(%User{} = user, token) when is_binary(token) do
    if FzHttp.Crypto.equal?(token, user.sign_in_token_hash) do
      User.Query.by_id(user.id)
      |> User.Query.where_sign_in_token_is_not_expired()
      |> Ecto.Query.update(set: [sign_in_token_hash: nil, sign_in_token_created_at: nil])
      |> Ecto.Query.select([users: users], users)
      |> Repo.update_all([])
      |> case do
        {1, [user]} -> {:ok, user}
        {0, []} -> {:error, :token_expired}
      end
    else
      {:error, :invalid_token}
    end
  end

  def create_user(role, attrs, %Auth.Subject{actor: {:user, actor}} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_users_permission()),
         {:ok, user} <- create_user(role, attrs) do
      AuditLogs.log("user.create",
        actor_id: actor.id,
        actor_email: actor.email,
        ip_address: ip_address,
        target_type: "user",
        target_id: user.id,
        target_label: user.email
      )
      {:ok, user}
    end
  end

  def create_user(role, attrs) do
    changeset = User.Changeset.create_changeset(role, attrs)

    with {:ok, user} <- Repo.insert(changeset) do
      Telemetry.add_user()
      {:ok, user}
    end
  end

  def change_user(%User{} = user \\ %User{}) do
    Ecto.Changeset.change(user)
  end

  def update_user(%User{} = user, attrs, %Auth.Subject{actor: {:user, actor}} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_users_permission()),
         {:ok, updated_user} <-
           user
           |> User.Changeset.update_user_role(attrs, subject)
           |> User.Changeset.update_user_email(attrs)
           |> User.Changeset.update_user_password(attrs)
           |> Repo.update() do
      if user.role != updated_user.role do
        AuditLogs.log("user.role.change",
          actor_id: actor.id,
          actor_email: actor.email,
          ip_address: ip_address,
          target_type: "user",
          target_id: updated_user.id,
          target_label: updated_user.email,
          metadata: %{old_role: to_string(user.role), new_role: to_string(updated_user.role)}
        )

        # Role is part of the identity payload — invalidate the
        # proxy's per-VPN-IP cache. Other update_user fields
        # (password, email) don't appear in the identity payload.
        FzHttp.L7.broadcast_identity_change(updated_user)
      end
      {:ok, updated_user}
    end
  end

  def update_user(%User{} = user, attrs) do
    user
    |> User.Changeset.update_user_role(attrs)
    |> User.Changeset.update_user_email(attrs)
    |> User.Changeset.update_user_password(attrs)
    |> Repo.update()
  end

  @doc """
  Update a user's L7 access_scope (`:limited` | `:all`). Admin only,
  audited. `:all` is a break-glass bypass — never set by default,
  always logged with both before+after values.
  """
  def set_access_scope(%User{} = user, scope,
                       %Auth.Subject{actor: {:user, actor}} = subject, ip_address \\ nil)
      when scope in [:limited, :all] do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_users_permission()) do
      if user.access_scope == scope do
        {:ok, user}
      else
        case user
             |> Ecto.Changeset.change(%{access_scope: scope})
             |> Repo.update() do
          {:ok, updated} ->
            AuditLogs.log("user.access_scope.change",
              actor_id: actor.id,
              actor_email: actor.email,
              ip_address: ip_address,
              target_type: "user",
              target_id: updated.id,
              target_label: updated.email,
              metadata: %{
                before: to_string(user.access_scope),
                after:  to_string(scope)
              }
            )

            FzHttp.L7.broadcast_identity_change(updated)

            {:ok, updated}

          other ->
            other
        end
      end
    end
  end

  def update_self(attrs, %Auth.Subject{actor: {:user, %User{} = user}} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.edit_own_profile_permission()),
         {:ok, updated_user} <-
           user
           |> User.Changeset.update_user_password(attrs)
           |> Repo.update() do
      AuditLogs.log("user.password.change",
        actor_id: user.id,
        actor_email: user.email,
        ip_address: ip_address,
        target_type: "user",
        target_id: user.id,
        target_label: user.email
      )
      {:ok, updated_user}
    end
  end

  def disable_user(%User{} = user) do
    user
    |> User.Changeset.disable_user()
    |> Repo.update()
    |> case do
      {:ok, user} ->
        FzHttp.Telemetry.disable_user()
        FzHttpWeb.Endpoint.broadcast("users_socket:#{user.id}", "disconnect", %{})
        AuditLogs.log("user.disable",
          target_type: "user",
          target_id: user.id,
          target_label: user.email,
          metadata: %{reason: "oidc_token_refresh_failed"}
        )
        {:ok, user}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def delete_user(%User{} = user, %Auth.Subject{actor: {:user, actor}} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_users_permission()),
         :ok <- ensure_not_last_admin(user),
         {:ok, deleted_user} <- Repo.delete(user, stale_error_field: :id) do
      Telemetry.delete_user()
      AuditLogs.log("user.delete",
        actor_id: actor.id,
        actor_email: actor.email,
        ip_address: ip_address,
        target_type: "user",
        target_id: user.id,
        target_label: user.email
      )
      {:ok, deleted_user}
    end
  end

  defp ensure_not_last_admin(%User{role: :admin, id: id}) do
    remaining_admins_count =
      User.Query.by_role(:admin)
      |> User.Query.by_id({:not, id})
      |> Repo.aggregate(:count)

    if remaining_admins_count >= 1 do
      :ok
    else
      {:error, :cant_delete_the_last_admin}
    end
  end

  defp ensure_not_last_admin(%User{}) do
    :ok
  end

  def setting_projection(user) do
    user.id
  end

  def as_settings do
    User.Query.select_id_map()
    |> Repo.all()
    |> Enum.map(&setting_projection/1)
    |> MapSet.new()
  end

  def update_last_signed_in(user, %{provider: provider}) do
    method =
      case provider do
        :identity -> "email"
        other -> to_string(other)
      end

    user
    |> User.Changeset.update_last_signed_in(%{
      last_signed_in_at: DateTime.utc_now(),
      last_signed_in_method: method
    })
    |> Repo.update()
  end

  def vpn_session_expires_at(user) do
    DateTime.add(user.last_signed_in_at, Config.fetch_config!(:vpn_session_duration))
  end

  def vpn_session_expired?(user) do
    cond do
      is_nil(user.last_signed_in_at) && Config.fetch_config!(:require_mfa) ->
        true

      is_nil(user.last_signed_in_at) ->
        false

      not Config.vpn_sessions_expire?() ->
        false

      true ->
        DateTime.diff(vpn_session_expires_at(user), DateTime.utc_now()) <= 0
    end
  end
end
