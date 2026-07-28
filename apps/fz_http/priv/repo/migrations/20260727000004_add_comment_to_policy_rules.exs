defmodule FzHttp.Repo.Migrations.AddCommentToPolicyRules do
  use Ecto.Migration

  def change do
    # Human-readable memo -- admin's note of what a rule is for
    # ("Grafana on 10.99.0.5:443", "block old wiki", "SRE-only
    # metrics backend"). Renders inline in the rules table so
    # the business intent shows next to the destination.
    alter table(:policy_rules) do
      add(:comment, :string, size: 200)
    end
  end
end
