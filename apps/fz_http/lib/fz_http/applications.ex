defmodule FzHttp.Applications do
  @moduledoc """
  Managed L7 applications context (ADR-007, ADR-014).

  Admin-only at the controller layer. The L7 proxy reads enabled apps
  from the policy bundle compiled by `FzHttp.L7.BundleBuilder` (L7-B);
  this context's `list_enabled_for_bundle/0` is the data source for
  that compile step.

  Mutations broadcast on `nexguard:l7:apps` so the bundle builder
  recompiles + PubSubs `{:bundle_updated, version}` to the proxy.
  """

  import Ecto.Query

  alias FzHttp.{Repo, Auth, AuditLogs, AccessGroups}
  alias FzHttp.Applications.{Application, AllowedGroup, Authorizer}
  alias FzHttp.L7.VipAllocator
  alias Phoenix.PubSub

  @topic "nexguard:l7:apps"

  # ── Changesets (for LiveView form preview) ──────────────────────

  @doc """
  Empty changeset for a new application form.
  """
  def change_application, do: Application.Changeset.create_changeset(%{})

  @doc """
  Changeset bound to attrs for live validation via `phx-change`.
  """
  def change_new_application(attrs), do: Application.Changeset.create_changeset(attrs)

  @doc """
  Changeset for editing an existing application.
  """
  def change_application(%Application{} = app, attrs \\ %{}),
    do: Application.Changeset.update_changeset(app, attrs)

  # ── Queries ─────────────────────────────────────────────────────

  def list_applications(%Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.view_applications_permission()) do
      query =
        from a in Application,
          left_join: ag in assoc(a, :allowed_group_links),
          group_by: a.id,
          select_merge: %{allowed_group_count: count(ag.group_id)},
          order_by: a.name

      {:ok, query |> Authorizer.for_subject(subject) |> Repo.all()}
    end
  end

  def fetch_application_by_id(id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.view_applications_permission()),
         true <- valid_uuid?(id) do
      Application
      |> Authorizer.for_subject(subject)
      |> where([a], a.id == ^id)
      |> preload(:allowed_groups)
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        app -> {:ok, app}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Internal — system call from `FzHttp.L7.BundleBuilder`. Returns only
  enabled apps with required groups preloaded. No subject.
  """
  def list_enabled_for_bundle do
    from(a in Application,
      where: a.enabled == true,
      preload: [:allowed_groups]
    )
    |> Repo.all()
  end

  # ── Mutations ───────────────────────────────────────────────────

  def create_application(attrs, %Auth.Subject{} = subject, ip_address \\ nil) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.manage_applications_permission()) do
      result =
        Repo.transaction(fn ->
          # Allocate inside the same transaction so the advisory lock
          # spans SELECT next-free + INSERT — two concurrent admin
          # requests can't collide on the same VIP.
          vip = VipAllocator.allocate_inside_transaction()

          attrs = Map.put(attrs_map(attrs), "virtual_ip", vip)

          case attrs |> Application.Changeset.create_changeset() |> Repo.insert() do
            {:ok, app}        -> app
            {:error, change}  -> Repo.rollback(change)
          end
        end)

      case result do
        {:ok, app} ->
          broadcast(:apps_changed)

          audit(subject, "application.create", app, ip_address, %{
            hostname: app.hostname,
            virtual_ip: inet_to_string(app.virtual_ip),
            cert_source: app.cert_source
          })

          {:ok, app}

        {:error, :exhausted} ->
          {:error, :vip_subnet_exhausted}

        {:error, %Ecto.Changeset{} = cs} ->
          {:error, cs}

        other ->
          other
      end
    end
  end

  def update_application(%Application{} = app, attrs, %Auth.Subject{} = subject,
                          ip_address \\ nil) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.manage_applications_permission()),
         changeset <- Application.Changeset.update_changeset(app, attrs),
         {:ok, updated} <- Repo.update(changeset) do
      broadcast(:apps_changed)

      audit(subject, "application.update", updated, ip_address, %{
        before: %{
          name: app.name,
          backend: app.backend,
          tls_mode: app.tls_mode
        },
        after: %{
          name: updated.name,
          backend: updated.backend,
          tls_mode: updated.tls_mode
        }
      })

      {:ok, updated}
    end
  end

  def set_application_enabled(%Application{} = app, value, %Auth.Subject{} = subject,
                               ip_address \\ nil)
      when is_boolean(value) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.manage_applications_permission()) do
      if app.enabled == value do
        {:ok, app}
      else
        case app
             |> Application.Changeset.set_enabled_changeset(value)
             |> Repo.update() do
          {:ok, updated} ->
            broadcast(:apps_changed)

            audit(subject, "application.enabled.change", updated, ip_address, %{
              before: app.enabled,
              after: value
            })

            {:ok, updated}

          other ->
            other
        end
      end
    end
  end

  def delete_application(%Application{} = app, %Auth.Subject{} = subject, ip_address \\ nil) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.manage_applications_permission()),
         {:ok, deleted} <- Repo.delete(app) do
      broadcast(:apps_changed)

      audit(subject, "application.delete", deleted, ip_address, %{
        hostname: deleted.hostname,
        virtual_ip: inet_to_string(deleted.virtual_ip)
      })

      {:ok, deleted}
    end
  end

  # ── Allowed groups (M:N) ────────────────────────────────────────

  def add_allowed_group(%Application{} = app, %AccessGroups.Group{} = group,
                        %Auth.Subject{} = subject, ip_address \\ nil) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.manage_l7_policy_permission()) do
      attrs = %{application_id: app.id, group_id: group.id}

      case %AllowedGroup{}
           |> Ecto.Changeset.cast(attrs, [:application_id, :group_id])
           |> Ecto.Changeset.unique_constraint([:application_id, :group_id],
                name: :application_allowed_groups_pkey,
                message: "group is already allowed for this app")
           |> Repo.insert() do
        {:ok, link} ->
          broadcast(:apps_changed)

          audit(subject, "application.allow_group", app, ip_address, %{
            group_id: group.id,
            group_name: group.name
          })

          {:ok, link}

        other ->
          other
      end
    end
  end

  def remove_allowed_group(%Application{} = app, %AccessGroups.Group{} = group,
                            %Auth.Subject{} = subject, ip_address \\ nil) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.manage_l7_policy_permission()) do
      case Repo.get_by(AllowedGroup, application_id: app.id, group_id: group.id) do
        nil ->
          {:error, :not_found}

        link ->
          {:ok, _} = Repo.delete(link)
          broadcast(:apps_changed)

          audit(subject, "application.revoke_group", app, ip_address, %{
            group_id: group.id,
            group_name: group.name
          })

          {:ok, :removed}
      end
    end
  end

  # ── PubSub ──────────────────────────────────────────────────────

  def subscribe,   do: PubSub.subscribe(FzHttp.PubSub, @topic)
  def unsubscribe, do: PubSub.unsubscribe(FzHttp.PubSub, @topic)

  defp broadcast(msg), do: PubSub.broadcast(FzHttp.PubSub, @topic, msg)

  # ── Helpers ─────────────────────────────────────────────────────

  # Normalise an `%{key: ...}` attrs map to string keys so we can
  # `Map.put` the VIP alongside admin form input without a mixed-key
  # map blowing up the cast.
  defp attrs_map(attrs) when is_map(attrs) do
    attrs
    |> Enum.into(%{}, fn
      {k, v} when is_atom(k)   -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end

  defp audit(%Auth.Subject{actor: {:user, actor}}, action, app, ip_address, metadata) do
    AuditLogs.log(action,
      actor_id: actor.id,
      actor_email: actor.email,
      ip_address: ip_address,
      target_type: "application",
      target_id: app.id,
      target_label: app.hostname || app.name,
      metadata: metadata
    )
  end

  defp audit(_subject, _action, _app, _ip, _metadata), do: :ok

  defp inet_to_string(%Postgrex.INET{address: addr}),
    do: addr |> :inet.ntoa() |> List.to_string()

  defp inet_to_string(_), do: nil

  defp valid_uuid?(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> true
      :error   -> false
    end
  end

  defp valid_uuid?(_), do: false
end
