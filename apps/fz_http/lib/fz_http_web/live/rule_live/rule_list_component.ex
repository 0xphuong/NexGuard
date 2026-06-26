defmodule FzHttpWeb.RuleLive.RuleListComponent do
  @moduledoc """
  Manages a single egress rule list — either Allow or Deny, decided
  by the `:id` assign (`:allowlist` / `:denylist`).

  R-B (v3.0.10): the add-rule form used to render as the FIRST row
  of the rule table. Visually it confused readers — the input row's
  weight competed with data rows, the submit button hid in column
  five, and the empty-state row landed below the form, implying the
  form itself was "the empty state". The form is now an explicit
  card above the table.

  R-C: search filter scoped to the panel — matches destination CIDR
  or the user_id-resolved email. Filter state is preserved across
  re-renders so adding/deleting a rule doesn't reset the query.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Rules
  alias FzHttp.Users

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    rules = rule_list(assigns)
    filters = Map.get(socket.assigns, :filters, default_filters())

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       action: action(assigns.id),
       all_rules: rules,
       users: users(assigns.subject),
       changeset: socket.assigns[:changeset] || Rules.new_rule(),
       port_rules_supported: Rules.port_rules_supported?(),
       filters: filters
     )
     |> assign_filtered()}
  end

  @impl Phoenix.LiveComponent
  def handle_event("change", %{"rule" => attrs}, socket) do
    changeset = Rules.new_rule(attrs)
    {:noreply, assign(socket, :changeset, changeset)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("add_rule", %{"rule" => attrs}, socket) do
    case Rules.create_rule(attrs, socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, _rule} ->
        rules = rule_list(socket.assigns)

        {:noreply,
         socket
         |> assign(:all_rules, rules)
         |> assign(:changeset, Rules.new_rule())
         |> assign_filtered()}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("delete_rule", %{"rule_id" => rule_id}, socket) do
    with {:ok, rule} <- Rules.fetch_rule_by_id(rule_id, socket.assigns.subject),
         {:ok, _rule} <-
           Rules.delete_rule(rule, socket.assigns.subject, socket.assigns[:remote_ip]) do
      rules = rule_list(socket.assigns)

      {:noreply,
       socket
       |> assign(:all_rules, rules)
       |> assign_filtered()}
    else
      {:error, msg} ->
        {:noreply, put_flash(socket, :error, "Couldn't delete rule. #{msg}")}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = Map.merge(socket.assigns.filters, params)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign_filtered()}
  end

  @impl Phoenix.LiveComponent
  def handle_event("reset_filter", _params, socket) do
    {:noreply,
     socket
     |> assign(:filters, default_filters())
     |> assign_filtered()}
  end

  def action(:allowlist), do: :accept
  def action(:denylist),  do: :drop

  defp rule_list(%{id: :allowlist}), do: Rules.allowlist()
  defp rule_list(%{id: :denylist}),  do: Rules.denylist()

  defp users(subject) do
    {:ok, users} = Users.list_users(subject)

    users
    |> Stream.map(&{&1.id, &1.email})
    |> Map.new()
  end

  defp user_options(users) do
    Enum.map(users, fn {id, email} -> {email, id} end)
  end

  defp port_type_options do
    %{TCP: :tcp, UDP: :udp}
  end

  defp port_type_display(nil), do: nil
  defp port_type_display(:tcp), do: "TCP"
  defp port_type_display(:udp), do: "UDP"

  # ── Filter state + apply ───────────────────────────────────────

  defp default_filters, do: %{"search" => ""}

  defp assign_filtered(socket) do
    filtered =
      apply_filters(socket.assigns.all_rules, socket.assigns.users, socket.assigns.filters)

    assign(socket, :rule_list, filtered)
  end

  defp apply_filters(rules, _users, %{"search" => ""}), do: rules

  defp apply_filters(rules, users, %{"search" => query}) do
    q = String.downcase(query)

    Enum.filter(rules, fn r ->
      destination_match?(r, q) or user_email_match?(r, users, q)
    end)
  end

  defp destination_match?(rule, q) do
    rule.destination
    |> destination_string()
    |> String.downcase()
    |> String.contains?(q)
  end

  defp destination_string(%Postgrex.INET{} = inet), do: FzHttp.Types.INET.to_string(inet)
  defp destination_string(other), do: to_string(other)

  defp user_email_match?(%{user_id: nil}, _users, _q), do: false

  defp user_email_match?(%{user_id: uid}, users, q) do
    case users[uid] do
      nil   -> false
      email -> String.contains?(String.downcase(email), q)
    end
  end

  # ── Presentation helpers used by the template ──────────────────

  def panel_title(:accept), do: "Allowlist"
  def panel_title(:drop),   do: "Denylist"

  def panel_icon(:accept), do: "mdi-check-circle-outline"
  def panel_icon(:drop),   do: "mdi-cancel"

  def empty_title(:accept), do: "No allow rules"
  def empty_title(:drop),   do: "No deny rules"

  def empty_hint(:accept),
    do: "Add a rule to grant explicit access to a destination or port range."

  def empty_hint(:drop),
    do: "Add a rule to block traffic to a destination or port range."

  def filters_active?(%{"search" => s}), do: s != ""
end
