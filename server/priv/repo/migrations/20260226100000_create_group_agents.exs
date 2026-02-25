defmodule Vibe.Repo.Migrations.CreateGroupAgents do
  use Ecto.Migration

  def change do
    create table(:group_agents, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :chat_id, references(:chats, type: :string, on_delete: :delete_all), null: false
      add :enabled, :boolean, default: true, null: false
      add :name, :string, default: "Vibe AI", null: false
      add :system_prompt, :text, null: false
      add :avatar_url, :text
      add :created_by, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps()
    end

    create unique_index(:group_agents, [:chat_id])
    create index(:group_agents, [:created_by])

    create table(:group_agent_memory, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :chat_id, references(:chats, type: :string, on_delete: :delete_all), null: false
      add :messages, :jsonb, default: "[]", null: false
      add :summary, :text
      add :total_messages_processed, :integer, default: 0, null: false
      add :last_compacted_at, :naive_datetime

      timestamps()
    end

    create unique_index(:group_agent_memory, [:chat_id])
  end
end
