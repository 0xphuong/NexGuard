defmodule FzHttpWeb.LiveMFA do
  @moduledoc """
  Guards content behind MFA
  """
  use Phoenix.Component
  use FzHttpWeb, :helper
  import Phoenix.LiveView
  alias FzHttp.Auth.MFA

  def on_mount(_arg, _params, %{"logged_in_at" => logged_in_at}, socket) do
    user = socket.assigns.current_user

    if socket.assigns[:live_action] == :register_mfa do
      {:cont, socket}
    else
      with {:ok, mfa} <- MFA.fetch_last_used_method_by_user_id(user.id),
           true <- DateTime.compare(logged_in_at, mfa.last_used_at) == :gt do
        {:halt, redirect(socket, to: ~p"/mfa/auth/#{mfa.id}")}
      else
        {:error, :not_found} ->
          if FzHttp.Config.fetch_config!(:require_mfa) do
            {:halt, redirect(socket, to: mfa_registration_path(user))}
          else
            {:cont, socket}
          end

        false ->
          {:cont, socket}
      end
    end
  end

  def on_mount(_arg, _params, _session, socket) do
    {:halt, redirect(socket, to: ~p"/")}
  end

  defp mfa_registration_path(%{role: :admin}), do: ~p"/settings/account/register_mfa"
  defp mfa_registration_path(_user), do: ~p"/user_account/register_mfa"
end
