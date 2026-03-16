defmodule Vibe.Repo.Migrations.AddIsAgentAndMessageMetadata do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :is_agent, :boolean, default: false, null: false
    end

    create index(:users, [:is_agent])

    alter table(:messages) do
      add :metadata, :map, default: %{}, null: false
    end
  end
end
