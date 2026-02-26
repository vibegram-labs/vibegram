defmodule Vibe.Repo.Migrations.CreateGroupAgentDocuments do
  use Ecto.Migration

  def up do
    create table(:group_agent_documents, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :chat_id, references(:chats, type: :string, on_delete: :delete_all), null: false
      add :title, :text, null: false
      add :format, :string, null: false, default: "csv"
      add :relative_url, :text, null: false
      add :file_url, :text, null: false
      add :columns, {:array, :string}, null: false, default: []
      add :row_count, :integer, null: false, default: 0
      add :metadata, :map, null: false, default: %{}
      add :version, :integer, null: false
      add :is_current, :boolean, null: false, default: false
      add :change_type, :string, null: false, default: "create"
      add :previous_document_id, references(:group_agent_documents, type: :binary_id, on_delete: :nilify_all)
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps()
    end

    create unique_index(:group_agent_documents, [:chat_id, :version])
    create index(:group_agent_documents, [:chat_id, :inserted_at])
    create index(:group_agent_documents, [:previous_document_id])

    execute("""
    CREATE UNIQUE INDEX group_agent_documents_one_current_idx
    ON group_agent_documents (chat_id)
    WHERE is_current = true
    """)

    execute("ALTER TABLE group_agent_documents ENABLE ROW LEVEL SECURITY")

    execute("DROP POLICY IF EXISTS group_agent_documents_select_policy ON group_agent_documents")
    execute("DROP POLICY IF EXISTS group_agent_documents_insert_policy ON group_agent_documents")
    execute("DROP POLICY IF EXISTS group_agent_documents_update_policy ON group_agent_documents")
    execute("DROP POLICY IF EXISTS group_agent_documents_delete_policy ON group_agent_documents")

    execute("""
    CREATE POLICY group_agent_documents_select_policy ON group_agent_documents
    FOR SELECT
    USING (vibe_is_chat_participant(chat_id))
    """)

    execute("""
    CREATE POLICY group_agent_documents_insert_policy ON group_agent_documents
    FOR INSERT
    WITH CHECK (
      vibe_current_user_id() IS NULL
      OR vibe_is_chat_participant(chat_id)
    )
    """)

    execute("""
    CREATE POLICY group_agent_documents_update_policy ON group_agent_documents
    FOR UPDATE
    USING (
      vibe_current_user_id() IS NULL
      OR vibe_is_chat_participant(chat_id)
    )
    WITH CHECK (
      vibe_current_user_id() IS NULL
      OR vibe_is_chat_participant(chat_id)
    )
    """)

    execute("""
    CREATE POLICY group_agent_documents_delete_policy ON group_agent_documents
    FOR DELETE
    USING (
      vibe_current_user_id() IS NULL
      OR vibe_is_chat_admin(chat_id)
    )
    """)
  end

  def down do
    execute("DROP POLICY IF EXISTS group_agent_documents_select_policy ON group_agent_documents")
    execute("DROP POLICY IF EXISTS group_agent_documents_insert_policy ON group_agent_documents")
    execute("DROP POLICY IF EXISTS group_agent_documents_update_policy ON group_agent_documents")
    execute("DROP POLICY IF EXISTS group_agent_documents_delete_policy ON group_agent_documents")

    execute("ALTER TABLE group_agent_documents DISABLE ROW LEVEL SECURITY")

    drop_if_exists index(:group_agent_documents, [:previous_document_id])
    drop_if_exists index(:group_agent_documents, [:chat_id, :inserted_at])
    drop_if_exists index(:group_agent_documents, [:chat_id, :version])
    execute("DROP INDEX IF EXISTS group_agent_documents_one_current_idx")

    drop table(:group_agent_documents)
  end
end
