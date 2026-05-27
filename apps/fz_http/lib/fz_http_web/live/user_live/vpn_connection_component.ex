defmodule FzHttpWeb.UserLive.VPNConnectionComponent do
  @moduledoc """
  Handles user form.
  """
  use FzHttpWeb, :live_component

  import Ecto.Changeset
  alias FzHttp.Repo

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign_new(:show_confirm, fn -> false end)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div>
      <label class="ng-toggle">
        <input
          type="checkbox"
          phx-target={@myself}
          name="toggle_disabled_at"
          phx-click="request_toggle"
          disabled={assigns[:disabled]}
          checked={!@user.disabled_at}
          value={if(@user.disabled_at, do: "on")}
        />
        <span class="ng-toggle-track"><span class="ng-toggle-thumb"></span></span>
      </label>

      <%= if @show_confirm do %>
        <div class="modal is-active"
             phx-window-keydown="cancel_toggle"
             phx-key="escape"
             phx-target={@myself}>
          <div class="modal-background" phx-click="cancel_toggle" phx-target={@myself}></div>
          <div class="modal-card">
            <header class="modal-card-head">
              <p class="modal-card-title">
                <i class="mdi mdi-wifi-off" style="color:#dc2626;margin-right:0.4rem"></i>
                Disable VPN Connection
              </p>
              <button class="ng-modal-close" aria-label="Close" phx-click="cancel_toggle" phx-target={@myself}>
                <i class="mdi mdi-close"></i>
              </button>
            </header>
            <section class="modal-card-body">
              <p style="color:#1e293b;margin-bottom:0.875rem">
                Disable VPN access for:
              </p>
              <div style="background:#fef2f2;border:1px solid #fecaca;border-radius:6px;
                          padding:0.625rem 0.875rem;margin-bottom:1.125rem;
                          font-family:'Fira Mono',monospace;font-size:0.9375rem;color:#991b1b">
                <%= @user.email %>
              </div>
              <p style="color:#475569;font-size:0.875rem;line-height:1.6">
                All active WireGuard sessions will be dropped immediately.
              </p>
            </section>
            <footer class="modal-card-foot">
              <button class="ng-secondary-btn" phx-click="cancel_toggle" phx-target={@myself}>
                Cancel
              </button>
              <button
                class="ng-danger-btn"
                phx-click="confirm_toggle"
                phx-target={@myself}
                style="background:#dc2626;color:#fff"
              >
                <i class="mdi mdi-wifi-off"></i> Disable VPN
              </button>
            </footer>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("request_toggle", params, socket) do
    to_disable = !params["value"]

    if to_disable do
      {:noreply, assign(socket, :show_confirm, true)}
    else
      do_toggle(false, socket)
    end
  end

  def handle_event("confirm_toggle", _params, socket) do
    do_toggle(true, socket)
  end

  def handle_event("cancel_toggle", _params, socket) do
    {:noreply, assign(socket, :show_confirm, false)}
  end

  defp do_toggle(to_disable, socket) do
    user =
      socket.assigns.user
      |> change()
      |> put_change(
        :disabled_at,
        if(to_disable, do: DateTime.utc_now(), else: nil)
      )
      |> prepare_changes(fn
        %{changes: %{disabled_at: nil}} = changeset ->
          changeset

        %{data: user} = changeset ->
          FzHttp.Telemetry.disable_user()
          FzHttpWeb.Endpoint.broadcast("users_socket:#{user.id}", "disconnect", %{})
          changeset
      end)
      |> Repo.update!()

    {:noreply, socket |> assign(:user, user) |> assign(:show_confirm, false)}
  end
end
