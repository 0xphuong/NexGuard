defmodule FzHttp.Policies do
  @moduledoc """
  Named egress policies -- successor to per-user `FzHttp.Rules`.

  A policy owns a list of `PolicyRule` (destination + optional
  port + action) and is applied to users via the
  `users_policies` join table. `as_effective_rules/0` flattens
  the (user × policy_rule) cross product into projections that
  `FzWall.Server` consumes exactly the same way as legacy
  per-user rules -- so the fz_wall backend needed zero changes
  to accept policy-derived traffic.

  During the v3.3.x transition, `FzHttp.Events.set_rules/0`
  unions this context's output with the legacy `FzHttp.Rules`
  output. Admins can migrate at their pace. See `task.md` for
  the removal plan (v4.0.0).
  """

  alias FzHttp.{Repo, Auth, Validator, AuditLogs}
  alias FzHttp.Policies.{Authorizer, Policy, PolicyRule}

  # ── Policies ──────────────────────────────────────────────

  def count do
    Repo.aggregate(Policy.Query.all(), :count)
  end

  def fetch_policy_by_id(id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         true <- Validator.valid_uuid?(id) do
      Policy.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_policy_by_id!(id) do
    Policy.Query.by_id(id)
    |> Repo.one!()
  end

  def list_policies(%Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      # v4.0.4: the default policy is surfaced separately at
      # the top of the /policies page via `fetch_default_policy/1`,
      # so filter it out of the regular list to avoid a duplicate
      # row.
      import Ecto.Query

      Policy.Query.all()
      |> where([policies: p], p.is_default == false)
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    end
  end

  @doc """
  Fetch the single row marked `is_default = true`, or `nil`.
  """
  def fetch_default_policy(%Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()) do
      import Ecto.Query

      policy =
        Policy.Query.all()
        |> where([policies: p], p.is_default == true)
        |> Repo.one()

      {:ok, policy}
    end
  end

  @doc """
  Create-or-update the singleton default policy. Uses the
  dedicated `default_policy_changeset/2` that locks
  `is_default = true` + `applies_to_all_users = true`. Fires
  `Events.set_rules/0` so the catch-all synthesised rule
  updates nftables immediately.
  """
  def upsert_default_policy(attrs, %Auth.Subject{actor: {:user, actor}} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         {:ok, current} <- fetch_default_policy(subject),
         {:ok, policy} <-
           (current || %Policy{})
           |> Policy.Changeset.default_policy_changeset(attrs)
           |> Repo.insert_or_update() do
      AuditLogs.log(
        if(current, do: "policy.default_updated", else: "policy.default_created"),
        actor_id: actor.id,
        actor_email: actor.email,
        ip_address: ip_address,
        target_type: "policy",
        target_id: policy.id,
        target_label: "default",
        metadata: %{default_action: to_string(policy.default_action)}
      )

      FzHttp.Events.set_rules()
      {:ok, policy}
    end
  end

  @doc """
  Delete the default policy if one exists. Emits `set_rules/0`
  so the catch-all rule is removed from nftables. No-op when
  no default is set.
  """
  def clear_default_policy(%Auth.Subject{actor: {:user, actor}} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         {:ok, policy} <- fetch_default_policy(subject),
         false <- is_nil(policy),
         {:ok, deleted} <- Repo.delete(policy) do
      AuditLogs.log("policy.default_deleted",
        actor_id: actor.id,
        actor_email: actor.email,
        ip_address: ip_address,
        target_type: "policy",
        target_id: deleted.id,
        target_label: "default"
      )

      FzHttp.Events.set_rules()
      {:ok, deleted}
    else
      true -> {:ok, nil}
      other -> other
    end
  end

  def list_policies_for_user(user_id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         true <- Validator.valid_uuid?(user_id) do
      Policy.Query.by_user_id(user_id)
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    else
      false -> {:ok, []}
      other -> other
    end
  end

  def new_policy(attrs \\ %{}) do
    Policy.Changeset.create_changeset(attrs)
  end

  def change_policy(%Policy{} = policy, attrs \\ %{}) do
    Policy.Changeset.update_changeset(policy, attrs)
  end

  def create_policy(attrs, %Auth.Subject{actor: {:user, actor}} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         {:ok, policy} <- create_policy(attrs) do
      AuditLogs.log("policy.create",
        actor_id: actor.id,
        actor_email: actor.email,
        ip_address: ip_address,
        target_type: "policy",
        target_id: policy.id,
        target_label: policy.name,
        metadata: %{default_action: to_string(policy.default_action)}
      )

      {:ok, policy}
    end
  end

  def create_policy(attrs) do
    Policy.Changeset.create_changeset(attrs)
    |> Repo.insert()
  end

  def update_policy(%Policy{} = policy, attrs, %Auth.Subject{actor: {:user, actor}} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         {:ok, updated} <- Policy.Changeset.update_changeset(policy, attrs) |> Repo.update() do
      AuditLogs.log("policy.update",
        actor_id: actor.id,
        actor_email: actor.email,
        ip_address: ip_address,
        target_type: "policy",
        target_id: updated.id,
        target_label: updated.name,
        metadata: %{}
      )

      FzHttp.Events.set_rules()
      {:ok, updated}
    end
  end

  def delete_policy(%Policy{} = policy, %Auth.Subject{actor: {:user, actor}} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         {:ok, deleted} <- Repo.delete(policy) do
      AuditLogs.log("policy.delete",
        actor_id: actor.id,
        actor_email: actor.email,
        ip_address: ip_address,
        target_type: "policy",
        target_id: deleted.id,
        target_label: deleted.name,
        metadata: %{}
      )

      FzHttp.Events.set_rules()
      {:ok, deleted}
    end
  end

  # ── Policy rules ──────────────────────────────────────────

  def fetch_policy_rule_by_id(id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         true <- Validator.valid_uuid?(id) do
      case Repo.get(PolicyRule, id) do
        nil -> {:error, :not_found}
        rule -> {:ok, rule}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def list_policy_rules(policy_id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         true <- Validator.valid_uuid?(policy_id) do
      PolicyRule.Query.by_policy_id(policy_id)
      |> Repo.list()
    else
      false -> {:ok, []}
      other -> other
    end
  end

  def new_policy_rule(attrs \\ %{}) do
    PolicyRule.Changeset.create_changeset(attrs)
  end

  def change_policy_rule(%PolicyRule{} = rule, attrs \\ %{}) do
    PolicyRule.Changeset.update_changeset(rule, attrs)
  end

  def create_policy_rule(attrs, %Auth.Subject{actor: {:user, actor}} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         {:ok, rule} <- PolicyRule.Changeset.create_changeset(attrs) |> Repo.insert() do
      AuditLogs.log("policy_rule.create",
        actor_id: actor.id,
        actor_email: actor.email,
        ip_address: ip_address,
        target_type: "policy_rule",
        target_id: rule.id,
        target_label: to_string(rule.destination),
        metadata: %{
          policy_id: rule.policy_id,
          action: to_string(rule.action)
        }
      )

      FzHttp.Events.set_rules()
      {:ok, rule}
    end
  end

  def update_policy_rule(%PolicyRule{} = rule, attrs, %Auth.Subject{actor: {:user, actor}} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         {:ok, updated} <- PolicyRule.Changeset.update_changeset(rule, attrs) |> Repo.update() do
      AuditLogs.log("policy_rule.update",
        actor_id: actor.id,
        actor_email: actor.email,
        ip_address: ip_address,
        target_type: "policy_rule",
        target_id: updated.id,
        target_label: to_string(updated.destination),
        metadata: %{policy_id: updated.policy_id}
      )

      FzHttp.Events.set_rules()
      {:ok, updated}
    end
  end

  def delete_policy_rule(%PolicyRule{} = rule, %Auth.Subject{actor: {:user, actor}} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         {:ok, deleted} <- Repo.delete(rule) do
      AuditLogs.log("policy_rule.delete",
        actor_id: actor.id,
        actor_email: actor.email,
        ip_address: ip_address,
        target_type: "policy_rule",
        target_id: deleted.id,
        target_label: to_string(deleted.destination),
        metadata: %{policy_id: deleted.policy_id}
      )

      FzHttp.Events.set_rules()
      {:ok, deleted}
    end
  end

  # ── User assignments ──────────────────────────────────────

  @doc """
  Add a user to a policy. Idempotent -- if the row already
  exists, returns `{:ok, :already_assigned}` without touching
  the DB, so a UI double-click doesn't crash. On success also
  broadcasts `set_rules/0` so fz_wall picks up the new
  effective rules for this user immediately.
  """
  def add_user_to_policy(policy_id, user_id, %Auth.Subject{actor: {:user, actor}} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         true <- Validator.valid_uuid?(policy_id),
         true <- Validator.valid_uuid?(user_id) do
      # Idempotent insert against the composite PK -- a UI
      # double-click just observes `num_rows: 0`. Raw SQL used
      # instead of Repo.insert_all/3 because the join table has
      # no schema module (many_to_many is defined string-join
      # style on `Policy`), and insert_all's type inference for
      # binary_id columns without a schema is fragile.
      %Postgrex.Result{num_rows: rows} =
        Repo.query!(
          """
          INSERT INTO users_policies (user_id, policy_id, inserted_at)
          VALUES ($1::uuid, $2::uuid, now())
          ON CONFLICT DO NOTHING
          """,
          [Ecto.UUID.dump!(user_id), Ecto.UUID.dump!(policy_id)]
        )

      if rows > 0 do
        AuditLogs.log("policy.user_added",
          actor_id: actor.id,
          actor_email: actor.email,
          ip_address: ip_address,
          target_type: "policy",
          target_id: policy_id,
          metadata: %{user_id: user_id}
        )

        FzHttp.Events.set_rules()
        {:ok, :assigned}
      else
        {:ok, :already_assigned}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def remove_user_from_policy(policy_id, user_id, %Auth.Subject{actor: {:user, actor}} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         true <- Validator.valid_uuid?(policy_id),
         true <- Validator.valid_uuid?(user_id) do
      %Postgrex.Result{num_rows: rows} =
        Repo.query!(
          "DELETE FROM users_policies WHERE user_id = $1::uuid AND policy_id = $2::uuid",
          [Ecto.UUID.dump!(user_id), Ecto.UUID.dump!(policy_id)]
        )

      if rows > 0 do
        AuditLogs.log("policy.user_removed",
          actor_id: actor.id,
          actor_email: actor.email,
          ip_address: ip_address,
          target_type: "policy",
          target_id: policy_id,
          metadata: %{user_id: user_id}
        )

        FzHttp.Events.set_rules()
      end

      {:ok, rows}
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Add every existing user (that isn't already assigned) to the
  policy in a single `INSERT ... ON CONFLICT DO NOTHING` and
  fires `Events.set_rules/0` exactly once. Loop-calling
  `add_user_to_policy/4` for 50 users would trigger 50 nftables
  teardown+rebuild cycles (see `fz_wall.Server.{:set_rules, ...}`),
  which is unnecessary work when the admin's intent is one bulk
  action. Returns `{:ok, inserted_count}`.
  """
  def add_all_users_to_policy(policy_id, %Auth.Subject{actor: {:user, actor}} = subject, ip_address \\ nil) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         true <- Validator.valid_uuid?(policy_id) do
      %Postgrex.Result{num_rows: rows} =
        Repo.query!(
          """
          INSERT INTO users_policies (user_id, policy_id, inserted_at)
          SELECT u.id, $1::uuid, now()
          FROM users u
          ON CONFLICT DO NOTHING
          """,
          [Ecto.UUID.dump!(policy_id)]
        )

      if rows > 0 do
        AuditLogs.log("policy.users_bulk_added",
          actor_id: actor.id,
          actor_email: actor.email,
          ip_address: ip_address,
          target_type: "policy",
          target_id: policy_id,
          metadata: %{added_count: rows}
        )

        FzHttp.Events.set_rules()
      end

      {:ok, rows}
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  List users assigned to the given policy. Returns full
  `FzHttp.Users.User` structs so the admin UI can render
  email + role without a second query.
  """
  def list_users_in_policy(policy_id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_policies_permission()),
         true <- Validator.valid_uuid?(policy_id) do
      import Ecto.Query

      users =
        from(u in FzHttp.Users.User,
          join: up in FzHttp.Policies.UserPolicy,
          on: up.user_id == u.id,
          where: up.policy_id == ^policy_id
        )
        |> Repo.all()

      {:ok, users}
    else
      false -> {:ok, []}
      other -> other
    end
  end

  # ── Bridge to fz_wall ─────────────────────────────────────

  @doc """
  Flatten every (user, policy_rule) pair the assignments define
  into rule projections that match what `FzHttp.Rules.setting_projection/1`
  emits for per-user rules. `FzWall.Server` reads a `MapSet` of
  these projections and doesn't care whether they came from
  `rules` or `policy_rules`.

  Skips port_type/port_range fields when fz_wall's config flag
  reports port-based rules are unsupported.
  """
  def as_effective_rules do
    port_rules_supported? = port_rules_supported?()

    (global_rules(port_rules_supported?) ++
       per_user_rules(port_rules_supported?) ++
       default_policy_rules())
    |> MapSet.new()
  end

  # v4.0.4: synthesise the catch-all rules from the singleton
  # `is_default = true` policy. Emitted at end of the list so
  # in the set-based nftables model these land in the `ip_drop`
  # / `ip6_drop` (or accept) sets alongside anything an
  # ordinary global policy added. Emits BOTH IP families so a
  # single admin toggle covers v4 + v6 traffic (dual-stack
  # clients don't slip through the v4 catch-all with v6).
  defp default_policy_rules do
    import Ecto.Query

    case Policy.Query.all() |> where([policies: p], p.is_default == true) |> Repo.one() do
      nil ->
        []

      %Policy{default_action: action} ->
        [
          %{
            destination: "0.0.0.0/0",
            action: action,
            user_id: nil,
            port_type: nil,
            port_range: nil
          },
          %{
            destination: "::/0",
            action: action,
            user_id: nil,
            port_type: nil,
            port_range: nil
          }
        ]
    end
  end

  @doc """
  Whether the kernel/nftables build supports port-based rules.
  Read from `:fz_wall, :port_based_rules_supported` at
  application config time.

  Moved here from the retired `FzHttp.Rules` module in v4.0.0;
  the underlying config key (owned by fz_wall) is unchanged.
  """
  def port_rules_supported?,
    do: FzHttp.Config.fetch_env!(:fz_wall, :port_based_rules_supported)

  # v3.3.0 M6: policies with `applies_to_all_users=true` produce
  # a single rule per (destination, action, port*) with
  # `user_id=nil`. fz_wall's `get_user_chain(nil)` returns
  # `"forward"` (see apps/fz_wall/lib/fz_wall/cli/helpers/sets.ex)
  # -- one nftables element covers every user, including future
  # ones. No `users_policies` join needed.
  defp global_rules(port_rules_supported?) do
    import Ecto.Query

    base_query =
      from(pr in PolicyRule,
        join: p in FzHttp.Policies.Policy,
        on: p.id == pr.policy_id,
        where: p.applies_to_all_users == true,
        select: %{
          destination: pr.destination,
          action: pr.action,
          port_type: pr.port_type,
          port_range: pr.port_range
        }
      )

    query =
      if port_rules_supported? do
        base_query
      else
        from([pr, _p] in base_query, where: is_nil(pr.port_type))
      end

    query
    |> Repo.all()
    # Stamp `user_id: nil` in Elixir -- Ecto's `type/2` doesn't
    # accept a literal nil, and adding a fake `p.some_nil_field`
    # to the select would be more confusing than a plain map.
    |> Enum.map(fn r -> Map.put(r, :user_id, nil) end)
    |> Enum.map(&stringify_destination/1)
  end

  # Per-user rules from non-global policies: cross-product
  # (users_policies x policy_rules). One nft element per user
  # per rule -- the pre-M6 default behaviour, retained for
  # policies that must scope to a subset of users.
  defp per_user_rules(port_rules_supported?) do
    import Ecto.Query

    base_query =
      from(pr in PolicyRule,
        join: p in FzHttp.Policies.Policy,
        on: p.id == pr.policy_id,
        join: up in FzHttp.Policies.UserPolicy,
        on: up.policy_id == pr.policy_id,
        where: p.applies_to_all_users == false,
        select: %{
          destination: pr.destination,
          action: pr.action,
          user_id: up.user_id,
          port_type: pr.port_type,
          port_range: pr.port_range
        }
      )

    query =
      if port_rules_supported? do
        base_query
      else
        from([pr, _p, _up] in base_query, where: is_nil(pr.port_type))
      end

    query
    |> Repo.all()
    |> Enum.map(&stringify_destination/1)
  end

  # Legacy `Rules.setting_projection/1` casts `destination` to a
  # string (INET → CIDR text) for the fz_wall wire format. Match
  # that shape so the two rule streams merge cleanly in the
  # MapSet.union at `Events.set_rules/0`.
  defp stringify_destination(%{destination: dest} = rule) do
    %{rule | destination: to_string(dest)}
  end
end
