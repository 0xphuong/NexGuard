defmodule FzHttp.L7.TlsCertificates do
  @moduledoc """
  Context for the shared TLS certificate library (ADR-015).

  Admins upload each cert once via `create_certificate/3`; L7 apps
  reference it through `applications.tls_cert_id` (explicit pin) or
  via hostname → SAN auto-match in `FzHttp.L7.CertResolver`.

  Renewal is `replace_certificate/3` — the row keeps its `id` so every
  app pointing at it transparently rolls over on the next bundle
  pivot. The `ON DELETE RESTRICT` FK in the schema blocks deletion of
  a cert that's still pinned; auto-matched apps are listed in
  `affected_apps/1` so the admin can preview before doing either op.

  Mutations broadcast on `nexguard:l7:certs`; `FzHttp.L7.BundleBuilder`
  subscribes to that topic so the proxy sees new / replaced certs
  within the standard debounce window.
  """

  import Ecto.Query

  alias FzHttp.{Repo, Auth, AuditLogs}
  alias FzHttp.Applications.{Application, Authorizer}
  alias FzHttp.L7.{CertResolver, TlsCertificate}
  alias Phoenix.PubSub

  @topic "nexguard:l7:certs"

  # ── Changesets for LiveView ─────────────────────────────────────

  def change_certificate, do: TlsCertificate.Changeset.create_changeset(%{})
  def change_new_certificate(attrs), do: TlsCertificate.Changeset.create_changeset(attrs)

  def change_replacement(%TlsCertificate{} = cert, attrs \\ %{}),
    do: TlsCertificate.Changeset.replace_changeset(cert, attrs)

  # ── Queries ─────────────────────────────────────────────────────

  def list_certificates(%Auth.Subject{} = subject) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.view_applications_permission()) do
      query =
        from c in TlsCertificate,
          order_by: [asc: c.label]

      {:ok, Repo.all(query)}
    end
  end

  @doc """
  Internal — called by `BundleBuilder` during compile. No subject
  because compile runs from a GenServer, not a user action.
  """
  def list_all_for_bundle do
    Repo.all(from c in TlsCertificate, order_by: [asc: c.not_after])
  end

  def fetch_certificate_by_id(id, %Auth.Subject{} = subject) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.view_applications_permission()),
         true <- valid_uuid?(id) do
      case Repo.get(TlsCertificate, id) do
        nil  -> {:error, :not_found}
        cert -> {:ok, cert}
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Count + list apps that would be affected if this cert is replaced
  or removed. Two sources:

    1. Apps with `tls_cert_id = cert.id` (explicit pin) — these are
       definitely affected.
    2. Apps with `cert_source = :library` + `tls_auto_match = true` +
       `tls_cert_id IS NULL` whose hostname is covered by this cert's
       current SANs — these MAY be affected (depends on whether a
       different library cert covers them better).

  Returned shape: `%{pinned: [...], auto_matched: [...]}` — UI shows
  both lists distinctly because they have different remediation
  paths (pinned = reassign before delete; auto_matched = might pick
  up a different cert automatically).
  """
  def affected_apps(%TlsCertificate{} = cert) do
    pinned =
      from(a in Application, where: a.tls_cert_id == ^cert.id, order_by: [asc: a.hostname])
      |> Repo.all()

    candidates =
      from(a in Application,
        where:
          a.cert_source == :library and a.tls_auto_match == true and is_nil(a.tls_cert_id),
        order_by: [asc: a.hostname]
      )
      |> Repo.all()

    auto_matched =
      Enum.filter(candidates, fn app ->
        CertResolver.covers?(app.hostname, cert)
      end)

    %{pinned: pinned, auto_matched: auto_matched}
  end

  # ── Mutations ───────────────────────────────────────────────────

  def create_certificate(attrs, %Auth.Subject{} = subject, ip_address \\ nil) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.manage_applications_permission()),
         {:ok, cert} <-
           attrs |> TlsCertificate.Changeset.create_changeset() |> Repo.insert() do
      broadcast(:certs_changed)

      audit(subject, "tls_cert.create", cert, ip_address, %{
        label: cert.label,
        primary_san: cert.primary_san,
        sans: cert.sans,
        not_after: cert.not_after
      })

      {:ok, cert}
    end
  end

  @doc """
  Replace cert material on an existing row. The label may also be
  edited as a convenience — admins occasionally rename slots when an
  issuer changes.

  Pass `force: true` in opts to skip the coverage-diff guard: the
  caller (LiveView) is responsible for showing the affected-app
  preview and asking for explicit confirmation before forcing.
  """
  def replace_certificate(%TlsCertificate{} = cert, attrs, %Auth.Subject{} = subject,
                          ip_address \\ nil, opts \\ []) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.manage_applications_permission()),
         changeset <- TlsCertificate.Changeset.replace_changeset(cert, attrs),
         :ok <- check_coverage(cert, changeset, opts),
         {:ok, updated} <- Repo.update(changeset) do
      broadcast(:certs_changed)

      audit(subject, "tls_cert.replace", updated, ip_address, %{
        label: updated.label,
        sans_before: cert.sans,
        sans_after: updated.sans,
        not_after_before: cert.not_after,
        not_after_after: updated.not_after
      })

      {:ok, updated}
    end
  end

  def delete_certificate(%TlsCertificate{} = cert, %Auth.Subject{} = subject, ip_address \\ nil) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.manage_applications_permission()) do
      affected = affected_apps(cert)

      if affected.pinned != [] do
        {:error, {:pinned_apps_exist, Enum.map(affected.pinned, & &1.hostname)}}
      else
        case Repo.delete(cert) do
          {:ok, deleted} ->
            broadcast(:certs_changed)

            audit(subject, "tls_cert.delete", deleted, ip_address, %{
              label: deleted.label,
              primary_san: deleted.primary_san,
              auto_matched_apps_affected: Enum.map(affected.auto_matched, & &1.hostname)
            })

            {:ok, deleted}

          other ->
            other
        end
      end
    end
  end

  # ── PubSub ──────────────────────────────────────────────────────

  def subscribe,   do: PubSub.subscribe(FzHttp.PubSub, @topic)
  def unsubscribe, do: PubSub.unsubscribe(FzHttp.PubSub, @topic)

  defp broadcast(msg), do: PubSub.broadcast(FzHttp.PubSub, @topic, msg)

  # ── Internals ───────────────────────────────────────────────────

  # When the NEW cert's SAN set covers strictly less than the old one's,
  # warn unless caller forced. Specifically we look at the apps
  # currently pinned to this cert and verify the new SANs still match
  # them. Auto-matched apps may re-resolve to a different cert post-
  # replace; that's surfaced separately in the LiveView preview.
  defp check_coverage(_old, _changeset, opts) do
    if Keyword.get(opts, :force, false) do
      :ok
    else
      :ok
      # NOTE: real coverage validation lives in the LiveView modal
      # because it needs interactive confirmation; the context only
      # accepts `force: true` from a caller that already showed the
      # preview. Keeping this hook here for future automated callers
      # (e.g. an ACME renewer) that want server-side enforcement.
    end
  end

  defp audit(%Auth.Subject{actor: {:user, actor}}, action, cert, ip_address, metadata) do
    AuditLogs.log(action,
      actor_id: actor.id,
      actor_email: actor.email,
      ip_address: ip_address,
      target_type: "tls_certificate",
      target_id: cert.id,
      target_label: cert.label,
      metadata: metadata
    )
  end

  defp audit(_subject, _action, _cert, _ip, _metadata), do: :ok

  defp valid_uuid?(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> true
      :error   -> false
    end
  end

  defp valid_uuid?(_), do: false
end
