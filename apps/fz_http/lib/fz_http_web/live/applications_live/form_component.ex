defmodule FzHttpWeb.ApplicationsLive.FormComponent do
  @moduledoc """
  Create / edit a managed application. Wave 3b-1: covers name +
  hostname + backend + cert_source picker (step_ca path only).
  Upload cert path comes in 3b-2; required-groups picker in 3b-3;
  L7 rules row-editor in 3c.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Applications

  @impl Phoenix.LiveComponent
  def update(%{action: :new} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, Applications.change_application())
     |> assign(:cert_preview, nil)}
  end

  def update(%{action: :edit, application: app} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, Applications.change_application(app))
     |> assign(:cert_preview, preview_cert(app.cert_pem))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate", %{"application" => attrs}, %{assigns: %{action: :new}} = socket) do
    cs =
      attrs
      |> Applications.change_new_application()
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:changeset, cs)
     |> assign(:cert_preview, preview_cert(attrs["cert_pem"]))}
  end

  def handle_event("validate", %{"application" => attrs}, %{assigns: %{action: :edit}} = socket) do
    cs =
      socket.assigns.application
      |> Applications.change_application(attrs)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:changeset, cs)
     |> assign(:cert_preview, preview_cert(attrs["cert_pem"]))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"application" => attrs}, %{assigns: %{action: :new}} = socket) do
    case Applications.create_application(attrs, socket.assigns.subject,
                                          socket.assigns[:remote_ip]) do
      {:ok, app} ->
        {:noreply,
         socket
         |> put_flash(:info, "Application \"#{app.name}\" created.")
         |> push_redirect(to: ~p"/applications/#{app}")}

      {:error, :vip_subnet_exhausted} ->
        {:noreply, put_flash(socket, :error, "Out of virtual IPs in 10.99.0.0/16.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :changeset, cs)}
    end
  end

  def handle_event("save", %{"application" => attrs}, %{assigns: %{action: :edit}} = socket) do
    case Applications.update_application(socket.assigns.application, attrs,
                                          socket.assigns.subject, socket.assigns[:remote_ip]) do
      {:ok, app} ->
        {:noreply,
         socket
         |> put_flash(:info, "Application \"#{app.name}\" updated.")
         |> push_redirect(to: ~p"/applications/#{app}")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :changeset, cs)}
    end
  end

  # ── Cert preview (inline) ────────────────────────────────────────

  # Parse the pasted PEM and surface subject CN + SANs + not_after
  # so the admin can sanity-check what cert they're about to upload
  # without having to leave the form. Returns nil for empty / invalid
  # input — the template only renders the preview block when this is
  # non-nil, so a malformed PEM degrades gracefully (the changeset
  # validator will still raise the formal error on submit).
  defp preview_cert(pem) when is_binary(pem) and pem != "" do
    try do
      cert = X509.Certificate.from_pem!(pem)

      sans =
        case X509.Certificate.extension(cert, :subject_alt_name) do
          {:Extension, _, _, list} ->
            Enum.flat_map(list, fn
              {:dNSName, charlist} -> [to_string(charlist)]
              _ -> []
            end)

          _ ->
            []
        end

      {:Validity, _, not_after_asn1} = X509.Certificate.validity(cert)

      %{
        subject: subject_string(cert),
        sans: sans,
        not_after: format_asn1_time(not_after_asn1)
      }
    rescue
      _ -> nil
    end
  end

  defp preview_cert(_), do: nil

  defp subject_string(cert) do
    case X509.Certificate.subject(cert) do
      {:rdnSequence, _} = rdn -> X509.RDNSequence.to_string(rdn)
      _ -> "—"
    end
  end

  # Cert validity is encoded as one of {:utcTime, charlist} or
  # {:generalTime, charlist}. Render a short ISO-ish string.
  defp format_asn1_time({:utcTime, time}) when is_list(time) do
    s = to_string(time)
    # YYMMDDHHMMSSZ → 20YY-MM-DD HH:MM UTC
    case s do
      <<yy::binary-2, mm::binary-2, dd::binary-2, hh::binary-2, mi::binary-2, _rest::binary>> ->
        "20#{yy}-#{mm}-#{dd} #{hh}:#{mi} UTC"

      _ ->
        s
    end
  end

  defp format_asn1_time({:generalTime, time}) when is_list(time) do
    s = to_string(time)
    # YYYYMMDDHHMMSSZ
    case s do
      <<yyyy::binary-4, mm::binary-2, dd::binary-2, hh::binary-2, mi::binary-2, _rest::binary>> ->
        "#{yyyy}-#{mm}-#{dd} #{hh}:#{mi} UTC"

      _ ->
        s
    end
  end

  defp format_asn1_time(_), do: "—"
end
