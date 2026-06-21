defmodule FzHttp.OrgSettings.Settings.Changeset do
  use FzHttp, :changeset
  alias FzHttp.OrgSettings.Settings

  @doc """
  Update the single-row org_settings record. `id` is immutable
  (singleton enforced by DB CHECK); only boolean toggles change.
  """
  def update_changeset(%Settings{} = settings, attrs) do
    settings
    |> cast(attrs, [:l7_enabled])
    |> validate_required([:l7_enabled])
  end
end
