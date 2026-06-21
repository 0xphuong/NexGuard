defmodule FzHttp.AccessGroups do
  @moduledoc """
  L7 access groups + membership context (ADR-014).

  Admin-only at the controller layer; the L7 proxy reads materialised
  group lists out of the policy bundle (`FzHttp.L7.BundleBuilder`)
  rather than calling this context per request — see ADR-013.
  """

  import Ecto.Query

  alias FzHttp.{Repo, Auth, AuditLogs}
  alias FzHttp.Users
  alias FzHttp.AccessGroups.{Group, Membership, Authorizer}

  # ── Changesets (for LiveView form preview) ──────────────────────

  @doc """
  Empty changeset for a new group form.
  """
  def change_group, do: Group.Changeset.create_changeset(%{})

  @doc """
  Changeset bound to a struct + admin-supplied attrs for live form
  validation. Used by `phx-change="validate"` so the UI can show
  inline errors before the user clicks Submit.
  """
  def change_group(%Group{} = group, attrs \\ %{}) do
    Group.Changeset.update_changeset(group, attrs)
  end

  def change_new_group(attrs), do: Group.Changeset.create_changeset(attrs)

  # ── Queries ─────────────────────────────────────────────────────

  def list_groups(%Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.view_access_groups_permission()) do
      query =
        from g in Group,
          left_join: m in assoc(g, :memberships),
          group_by: g.id,
          select_merge: %{member_count: count(m.user_id)},
          order_by: g.name

      {:ok, query |> Authorizer.for_subject(subject) |> Repo.all()}
    end
  end

  def fetch_group_by_id(id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.view_access_groups_permission()),
         true <- valid_uuid?(id) do
      Group
      |> Authorizer.for_subject(subject)
      |> where([g], g.id == ^id)
      |> Repo.one()
      |> case do
        nil   -> {:error, :not_found}
        group -> {:ok, group}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Look up a group by name. Internal use only (e.g. SCIM
  reconciliation, seeds) — no permission check.
  """
  def get_group_by_name(name) when is_binary(name) do
    Repo.get_by(Group, name: name)
  end

  @doc """
  Used by `FzHttp.L7.BundleBuilder` (no subject — runs in a system
  context) to populate the policy bundle. Returns groups with their
  member user_ids preloaded.
  """
  def list_groups_with_members do
    Group
    |> preload(memberships: [:user])
    |> Repo.all()
  end

  @doc """
  Return all groups a user belongs to. Used by the identity API
  endpoint the L7 proxy queries (`/internal/sessions/by_vpn_ip/:ip`).
  No subject — system context.
  """
  def list_groups_for_user(%Users.User{} = user), do: list_groups_for_user(user.id)

  def list_groups_for_user(user_id) do
    from(g in Group,
      join: m in assoc(g, :memberships),
      where: m.user_id == ^user_id,
      order_by: g.name
    )
    |> Repo.all()
  end

  # ── Mutations: groups ───────────────────────────────────────────

  def create_group(attrs, %Auth.Subject{} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_access_groups_permission()),
         changeset <- Group.Changeset.create_changeset(attrs),
         {:ok, group} <- Repo.insert(changeset) do
      audit(subject, "access_group.create", group, ip_address, %{
        name: group.name,
        source: group.source
      })

      {:ok, group}
    end
  end

  def update_group(%Group{} = group, attrs, %Auth.Subject{} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_access_groups_permission()),
         changeset <- Group.Changeset.update_changeset(group, attrs),
         {:ok, updated} <- Repo.update(changeset) do
      audit(subject, "access_group.update", updated, ip_address, %{
        before: %{name: group.name, description: group.description},
        after:  %{name: updated.name, description: updated.description}
      })

      {:ok, updated}
    end
  end

  def delete_group(%Group{} = group, %Auth.Subject{} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_access_groups_permission()),
         {:ok, deleted} <- Repo.delete(group) do
      audit(subject, "access_group.delete", deleted, ip_address, %{
        name: deleted.name,
        cascade_warning:
          "memberships and application_allowed_groups entries cascaded"
      })

      {:ok, deleted}
    end
  end

  # ── Mutations: memberships ──────────────────────────────────────

  def add_member(%Group{} = group, %Users.User{} = user, %Auth.Subject{} = subject,
                 ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_access_groups_permission()),
         actor_id <- actor_user_id(subject),
         attrs <- %{
           user_id: user.id,
           group_id: group.id,
           source: :manual,
           added_by_id: actor_id
         },
         {:ok, membership} <- attrs |> Membership.Changeset.create_changeset() |> Repo.insert() do
      audit(subject, "access_group.add_member", group, ip_address, %{
        user_id: user.id,
        user_email: user.email
      })

      {:ok, membership}
    end
  end

  def remove_member(%Group{} = group, %Users.User{} = user, %Auth.Subject{} = subject,
                    ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_access_groups_permission()) do
      case Repo.get_by(Membership, user_id: user.id, group_id: group.id) do
        nil ->
          {:error, :not_found}

        membership ->
          {:ok, _} = Repo.delete(membership)

          audit(subject, "access_group.remove_member", group, ip_address, %{
            user_id: user.id,
            user_email: user.email
          })

          {:ok, :removed}
      end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp actor_user_id(%Auth.Subject{actor: {:user, %Users.User{id: id}}}), do: id
  defp actor_user_id(_), do: nil

  defp audit(subject, action, group, ip_address, metadata) do
    case subject.actor do
      {:user, actor} ->
        AuditLogs.log(action,
          actor_id: actor.id,
          actor_email: actor.email,
          ip_address: ip_address,
          target_type: "access_group",
          target_id: group.id,
          target_label: group.name,
          metadata: metadata
        )

      _ ->
        :ok
    end
  end

  defp valid_uuid?(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> true
      :error   -> false
    end
  end

  defp valid_uuid?(_), do: false
end
