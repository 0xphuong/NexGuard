defmodule FzHttpWeb.SettingLive.CertificateFormComponent do
  @moduledoc """
  Upload-new or replace-in-place modal for the TLS cert library
  (ADR-015).

  Two `:action`s share this component:

    * `:new`     — no existing cert; clean form, label required.
    * `:replace` — `:certificate` assign carries the existing row;
                   label pre-filled (editable), pem/key cleared so
                   the admin can't accidentally save the old material.

  Live preview surfaces SAN list / not_after / issuer the moment the
  admin pastes a cert — same parser as save validation, so what they
  see is what gets saved.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.L7.{CertParser, TlsCertificates}

  @impl Phoenix.LiveComponent
  def update(%{action: :new} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, TlsCertificates.change_certificate())
     |> assign(:cert_preview, nil)}
  end

  def update(%{action: :replace, certificate: cert} = assigns, socket) do
    # Pre-fill label only — pem/key blank so admin can't save the old
    # bytes. The changeset still requires both, so empty save fails.
    # Surface the affected app list so admin sees the blast radius
    # of the replace BEFORE pasting new material.
    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       :changeset,
       TlsCertificates.change_replacement(cert, %{"label" => cert.label})
     )
     |> assign(:cert_preview, nil)
     |> assign(:current, cert)
     |> assign(:affected, TlsCertificates.affected_apps(cert))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate", %{"tls_certificate" => attrs}, socket) do
    cs =
      case socket.assigns.action do
        :new ->
          TlsCertificates.change_new_certificate(attrs)

        :replace ->
          TlsCertificates.change_replacement(socket.assigns.certificate, attrs)
      end
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:changeset, cs)
     |> assign(:cert_preview, preview(attrs["pem"], attrs["key"]))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"tls_certificate" => attrs}, %{assigns: %{action: :new}} = socket) do
    case TlsCertificates.create_certificate(attrs, socket.assigns.subject,
                                             socket.assigns[:remote_ip]) do
      {:ok, cert} ->
        send(self(), {:certificates_refresh,
                      %{kind: :info, message: "Certificate \"#{cert.label}\" uploaded."}})

        {:noreply, push_patch(socket, to: socket.assigns.return_to)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :changeset, cs)}
    end
  end

  def handle_event("save", %{"tls_certificate" => attrs},
                    %{assigns: %{action: :replace, certificate: cert}} = socket) do
    # Force: true because the LiveView modal is showing the diff
    # preview already (or will when phase D adds the coverage check).
    # Context-level guard skipped — phase D will fill it in once we
    # decide the exact UX for "covers strictly less" warnings.
    case TlsCertificates.replace_certificate(cert, attrs, socket.assigns.subject,
                                              socket.assigns[:remote_ip], force: true) do
      {:ok, updated} ->
        send(self(), {:certificates_refresh,
                      %{kind: :info, message: "Certificate \"#{updated.label}\" replaced."}})

        {:noreply, push_patch(socket, to: socket.assigns.return_to)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :changeset, cs)}
    end
  end

  # ── Inline preview ──────────────────────────────────────────────

  defp preview(pem, key) when is_binary(pem) and is_binary(key) and pem != "" and key != "" do
    case CertParser.parse(pem, key) do
      {:ok, parsed} ->
        %{
          sans: parsed.sans,
          primary_san: parsed.primary_san,
          issuer: parsed.issuer,
          not_after: parsed.not_after
        }

      {:error, _} ->
        nil
    end
  end

  defp preview(_, _), do: nil
end
