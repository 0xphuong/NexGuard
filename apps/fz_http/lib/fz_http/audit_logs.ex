defmodule FzHttp.AuditLogs do
  @moduledoc """
  Immutable audit log for all security-relevant events.

  Usage:
      AuditLogs.log("auth.login.success",
        actor_id: user.id,
        actor_email: user.email,
        ip_address: remote_ip
      )

      AuditLogs.log("user.delete",
        actor_id: admin.id,
        actor_email: admin.email,
        target_type: "user",
        target_id: to_string(user.id),
        target_label: user.email
      )
  """

  import Ecto.Query

  alias FzHttp.Repo
  alias FzHttp.AuditLogs.AuditLog

  @page_size 50

  def page_size, do: @page_size

  @doc """
  Records a single audit event. Non-blocking — logs the error and returns :ok
  on changeset failure so callers never crash from a bad audit write.
  """
  @spec log(String.t(), keyword()) :: :ok
  def log(action, opts \\ []) do
    attrs = %{
      action:       action,
      actor_id:     opts[:actor_id],
      actor_email:  opts[:actor_email],
      target_type:  opts[:target_type],
      target_id:    opts[:target_id] && to_string(opts[:target_id]),
      target_label: opts[:target_label],
      ip_address:   opts[:ip_address],
      result:       to_string(opts[:result] || "success"),
      metadata:     opts[:metadata] || %{}
    }

    case %AuditLog{} |> AuditLog.changeset(attrs) |> Repo.insert() do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        require Logger
        Logger.error("AuditLogs.log failed: #{inspect(changeset.errors)}")
        :ok
    end
  end

  @doc "List logs with optional filters. Returns newest first."
  @spec list_logs(keyword()) :: [AuditLog.t()]
  def list_logs(filters \\ []) do
    AuditLog
    |> apply_filters(filters)
    |> order_by([l], desc: l.inserted_at)
    |> limit(@page_size)
    |> Repo.all()
  end

  @doc "Count logs matching filters."
  @spec count_logs(keyword()) :: non_neg_integer()
  def count_logs(filters \\ []) do
    AuditLog
    |> apply_filters(filters)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Delete audit logs older than the given datetime.
  Called by the retention scheduler.
  """
  @spec purge_before(DateTime.t()) :: {non_neg_integer(), nil}
  def purge_before(%DateTime{} = cutoff) do
    from(l in AuditLog, where: l.inserted_at < ^cutoff)
    |> Repo.delete_all()
  end

  # ── Filters ───────────────────────────────────────────────────

  defp apply_filters(query, []), do: query

  defp apply_filters(query, [{:actor_id, id} | rest]) do
    query |> where([l], l.actor_id == ^id) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:action, action} | rest]) do
    query |> where([l], l.action == ^action) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:result, result} | rest]) do
    query |> where([l], l.result == ^to_string(result)) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:target_type, type} | rest]) do
    query |> where([l], l.target_type == ^type) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:target_id, id} | rest]) do
    query |> where([l], l.target_id == ^to_string(id)) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:from, %DateTime{} = dt} | rest]) do
    query |> where([l], l.inserted_at >= ^dt) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:to, %DateTime{} = dt} | rest]) do
    query |> where([l], l.inserted_at <= ^dt) |> apply_filters(rest)
  end

  defp apply_filters(query, [{:category, cat} | rest]) when is_binary(cat) and cat != "" do
    prefix = cat <> ".%"
    query |> where([l], like(l.action, ^prefix)) |> apply_filters(rest)
  end

  # Free-text search across the four columns admins most often
  # forensic-grep by: actor email, target label, target id, IP.
  # Case-insensitive partial match via ILIKE.
  defp apply_filters(query, [{:search, q} | rest]) when is_binary(q) and q != "" do
    pattern = "%" <> q <> "%"

    query
    |> where(
      [l],
      ilike(l.actor_email, ^pattern) or
        ilike(l.target_label, ^pattern) or
        ilike(l.target_id, ^pattern) or
        ilike(l.ip_address, ^pattern)
    )
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:page, page} | rest]) when is_integer(page) and page > 0 do
    query |> offset(^((page - 1) * @page_size)) |> apply_filters(rest)
  end

  defp apply_filters(query, [_ | rest]), do: apply_filters(query, rest)
end
