defmodule FzHttpWeb.SearchLive do
  @moduledoc """
  Global ⌘K search modal — embedded in `admin.html.heex` so it's
  available on every admin page without per-page wiring.

  Lifecycle:

    * The `CmdKShortcut` JS hook (assets/js/hooks.js) listens for
      ⌘K / Ctrl-K at the window level and pushes `"toggle"` to this
      LiveView. Same shortcut closes it.
    * Esc + click-on-backdrop also close.
    * Typing in the input fires `"search"` which runs a SHORT-CIRCUIT
      query across Applications, Users, and Access Groups, returning
      the top N matches per category.

  Each result has `{label, href, kind}`. Click / Enter → push_navigate.

  Search is intentionally case-insensitive substring (`ILIKE %q%`).
  Fast enough at the scale a self-hosted NexGuard deployment ever
  hits (a few hundred users / dozens of apps); no need for tsvector
  yet. If it ever matters, swap the filters here.
  """
  use FzHttpWeb, :live_view_without_layout

  import Ecto.Query

  alias FzHttp.{Repo, Users}
  alias FzHttp.AccessGroups.Group
  alias FzHttp.Applications.Application

  @result_limit_per_kind 5

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    subject = session["subject"] || socket.assigns[:subject]

    {:ok,
     socket
     |> assign(:open, false)
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:subject, subject)}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle", _params, socket) do
    open = not socket.assigns.open

    {:noreply,
     socket
     |> assign(:open, open)
     |> assign(:query, "")
     |> assign(:results, [])}
  end

  def handle_event("close", _params, socket) do
    {:noreply,
     socket
     |> assign(:open, false)
     |> assign(:query, "")
     |> assign(:results, [])}
  end

  def handle_event("search", %{"q" => q}, socket) do
    results = run_search(q, socket.assigns.subject)

    {:noreply,
     socket
     |> assign(:query, q)
     |> assign(:results, results)}
  end

  def handle_event("navigate", %{"to" => href}, socket) do
    {:noreply,
     socket
     |> assign(:open, false)
     |> assign(:query, "")
     |> assign(:results, [])
     |> push_navigate(to: href)}
  end

  # ── Search implementation ──────────────────────────────────────

  defp run_search(q, _subject) when not is_binary(q) or byte_size(q) < 2 do
    []
  end

  defp run_search(q, _subject) do
    pattern = "%#{q}%"

    apps = search_applications(pattern)
    users = search_users(pattern)
    groups = search_groups(pattern)

    [
      {"Applications", apps},
      {"Users", users},
      {"Access Groups", groups}
    ]
    |> Enum.reject(fn {_kind, list} -> list == [] end)
  end

  defp search_applications(pattern) do
    from(a in Application,
      where: ilike(a.name, ^pattern) or ilike(a.hostname, ^pattern),
      order_by: [asc: a.name],
      limit: @result_limit_per_kind
    )
    |> Repo.all()
    |> Enum.map(fn app ->
      %{
        label: app.name,
        hint:  app.hostname,
        icon:  "mdi-application-cog-outline",
        href:  "/applications/#{app.id}"
      }
    end)
  end

  defp search_users(pattern) do
    from(u in Users.User,
      where: ilike(u.email, ^pattern),
      order_by: [asc: u.email],
      limit: @result_limit_per_kind
    )
    |> Repo.all()
    |> Enum.map(fn user ->
      %{
        label: user.email,
        hint:  Atom.to_string(user.role || :unprivileged),
        icon:  "mdi-account-circle-outline",
        href:  "/users/#{user.id}"
      }
    end)
  end

  defp search_groups(pattern) do
    from(g in Group,
      where: ilike(g.name, ^pattern),
      order_by: [asc: g.name],
      limit: @result_limit_per_kind
    )
    |> Repo.all()
    |> Enum.map(fn group ->
      %{
        label: group.name,
        hint:  group.description || "",
        icon:  "mdi-account-multiple-check-outline",
        href:  "/access-groups/#{group.id}"
      }
    end)
  end

end
