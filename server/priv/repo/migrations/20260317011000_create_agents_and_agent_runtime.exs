defmodule Vibe.Repo.Migrations.CreateAgentsAndAgentRuntime do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :owner_user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, default: "draft", null: false
      add :display_name, :string, null: false
      add :system_prompt, :text, default: "", null: false
      add :persona, :text
      add :avatar_url, :text
      add :welcome_message, :text
      add :enabled_tools, {:array, :string}, default: [], null: false
      add :output_modes, {:array, :string}, default: ["text"], null: false
      add :voice_provider, :string
      add :voice_profile, :string
      add :callback_url, :text
      add :webhook_secret_hash, :string, null: false
      add :secret_hint, :string, null: false
      add :published_at, :utc_datetime
      add :last_invoked_at, :utc_datetime

      timestamps()
    end

    create unique_index(:agents, [:agent_user_id])
    create index(:agents, [:owner_user_id])
    create index(:agents, [:status])

    create constraint(:agents, :agents_status_check,
             check: "status IN ('draft', 'published', 'disabled', 'archived')"
           )

    create table(:agent_invocations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :source, :string, null: false
      add :event_id, :string
      add :vibe_chat_id, :string
      add :external_user_id, :string
      add :request_payload, :map, default: %{}, null: false
      add :response_payload, :map, default: %{}, null: false
      add :status, :string, default: "completed", null: false
      add :error, :text

      timestamps()
    end

    create index(:agent_invocations, [:agent_id, :inserted_at])

    create unique_index(:agent_invocations, [:agent_id, :event_id],
             where: "event_id IS NOT NULL",
             name: :agent_invocations_agent_id_event_id_index
           )

    create table(:agent_delivery_events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :invocation_id, references(:agent_invocations, type: :binary_id, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :target_url, :text, null: false
      add :request_body, :map, default: %{}, null: false
      add :response_code, :integer
      add :status, :string, default: "pending", null: false
      add :attempt_count, :integer, default: 0, null: false
      add :last_error, :text

      timestamps()
    end

    create index(:agent_delivery_events, [:agent_id, :inserted_at])
    create index(:agent_delivery_events, [:status, :inserted_at])
  end
end
