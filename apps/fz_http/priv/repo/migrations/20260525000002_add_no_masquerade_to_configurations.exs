defmodule FzHttp.Repo.Migrations.AddNoMasqueradeToConfigurations do
  use Ecto.Migration

  def change do
    alter table(:configurations) do
      add(:gateway_no_masquerade_enabled, :boolean, default: false, null: false)

      add(:gateway_no_masquerade_cidrs, :text,
        default: "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16",
        null: false
      )
    end
  end
end
