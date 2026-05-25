defmodule FzHttp.Repo.Migrations.AddRequireMfaToConfigurations do
  use Ecto.Migration

  def change do
    alter table(:configurations) do
      add(:require_mfa, :boolean, default: false, null: false)
    end
  end
end
