defmodule FzHttp.OrgSettings do
  @moduledoc """
  Org-level toggles (ADR-014). Single-row singleton — see migration
  `20260620000006_create_org_settings.exs` for the seed + CHECK
  constraint that guarantees the row exists.

  Toggle changes broadcast on the `nexguard:l7:settings` topic so
  `fz_wall` (nftables TPROXY chain on/off) and the L7 proxy
  (graceful shutdown when killed) can react without polling.
  """

  alias FzHttp.{Repo, Auth, AuditLogs}
  alias FzHttp.OrgSettings.{Settings, Authorizer}
  alias Phoenix.PubSub

  @topic "nexguard:l7:settings"

  # ── Read ────────────────────────────────────────────────────────

  @doc "Always returns the singleton row — no nil case to handle."
  @spec get() :: Settings.t()
  def get, do: Repo.get!(Settings, 1)

  @doc "Convenience predicate for hot-path checks."
  @spec l7_enabled?() :: boolean()
  def l7_enabled?, do: get().l7_enabled

  # ── Write ───────────────────────────────────────────────────────

  @doc """
  Flip the org-wide L7 kill switch. Audited; broadcasts on
  `nexguard:l7:settings` so consumers (fz_wall TPROXY chain
  toggle, L7 proxy lifecycle) react in real time.
  """
  def set_l7_enabled(value, %Auth.Subject{} = subject, ip_address \\ nil)
      when is_boolean(value) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.manage_l7_settings_permission()) do
      current = get()

      if current.l7_enabled == value do
        # No-op — don't write or broadcast a non-change.
        {:ok, current}
      else
        case current
             |> Settings.Changeset.update_changeset(%{l7_enabled: value})
             |> Repo.update() do
          {:ok, updated} ->
            broadcast({:l7_enabled_changed, value})

            audit(subject, ip_address, %{
              before: current.l7_enabled,
              after: value
            })

            {:ok, updated}

          other ->
            other
        end
      end
    end
  end

  @doc """
  Update CoreDNS forward upstreams (primary + optional fallback).
  Broadcasts `{:dns_forward_changed, %{primary, fallback}}` on the
  same `nexguard:l7:settings` topic — `FzHttp.L7.CoreDnsCorefile`
  subscribes and regenerates the Corefile within ~1s. CoreDNS
  `reload 1s` plugin picks it up automatically; no container
  restart.
  """
  def set_dns_forward(primary, fallback, %Auth.Subject{} = subject, ip_address \\ nil)
      when is_list(primary) and is_list(fallback) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.manage_l7_settings_permission()) do
      current = get()

      attrs = %{
        coredns_forward_to: primary,
        coredns_forward_to_fallback: fallback
      }

      changeset = Settings.Changeset.update_changeset(current, attrs)

      cond do
        changeset.changes == %{} ->
          {:ok, current}

        not changeset.valid? ->
          {:error, changeset}

        true ->
          case Repo.update(changeset) do
            {:ok, updated} ->
              broadcast({:dns_forward_changed, %{
                primary: updated.coredns_forward_to,
                fallback: updated.coredns_forward_to_fallback
              }})

              audit_dns(subject, ip_address, %{
                before: %{
                  primary:  current.coredns_forward_to,
                  fallback: current.coredns_forward_to_fallback
                },
                after: %{
                  primary:  updated.coredns_forward_to,
                  fallback: updated.coredns_forward_to_fallback
                }
              })

              {:ok, updated}

            other ->
              other
          end
      end
    end
  end

  @doc """
  System-level seed of the DNS forward config from environment vars.
  Called once during application boot — see
  `FzHttp.Application.bootstrap_dns/0`. Won't overwrite a DB value
  that's already populated.
  """
  def seed_dns_from_env(primary, fallback) when is_list(primary) and is_list(fallback) do
    current = get()

    if current.coredns_forward_to == [] do
      current
      |> Settings.Changeset.update_changeset(%{
        coredns_forward_to: primary,
        coredns_forward_to_fallback: fallback
      })
      |> Repo.update()
      |> case do
        {:ok, _} = ok ->
          broadcast({:dns_forward_changed, %{primary: primary, fallback: fallback}})
          ok

        other ->
          other
      end
    else
      {:ok, current}
    end
  end

  # ── PubSub helpers ──────────────────────────────────────────────

  def subscribe, do: PubSub.subscribe(FzHttp.PubSub, @topic)
  def unsubscribe, do: PubSub.unsubscribe(FzHttp.PubSub, @topic)

  defp broadcast(msg), do: PubSub.broadcast(FzHttp.PubSub, @topic, msg)

  # ── Audit ───────────────────────────────────────────────────────

  defp audit(%Auth.Subject{actor: {:user, actor}}, ip_address, metadata) do
    AuditLogs.log("org_settings.l7_enabled.change",
      actor_id: actor.id,
      actor_email: actor.email,
      ip_address: ip_address,
      target_type: "org_settings",
      target_id: "1",
      target_label: "L7 enforcement toggle",
      metadata: metadata
    )
  end

  defp audit(_subject, _ip, _metadata), do: :ok

  defp audit_dns(%Auth.Subject{actor: {:user, actor}}, ip_address, metadata) do
    AuditLogs.log("org_settings.dns_forward.change",
      actor_id: actor.id,
      actor_email: actor.email,
      ip_address: ip_address,
      target_type: "org_settings",
      target_id: "1",
      target_label: "CoreDNS forward upstreams",
      metadata: metadata
    )
  end

  defp audit_dns(_subject, _ip, _metadata), do: :ok
end
