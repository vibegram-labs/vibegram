defmodule Vibe.Repo.Migrations.HardenChatRlsContext do
  use Ecto.Migration

  @agent_user_id "00000000-0000-0000-0000-000000000001"

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION vibe_is_chat_participant(target_chat_id text) RETURNS boolean
    LANGUAGE plpgsql STABLE AS $$
    DECLARE
      uid uuid;
    BEGIN
      uid := vibe_current_user_id();
      IF uid IS NULL THEN
        RETURN false;
      END IF;

      RETURN EXISTS (
        SELECT 1
        FROM chat_participants cp
        WHERE cp.chat_id = target_chat_id
          AND cp.user_id = uid
          AND coalesce(cp.deleted, false) = false
      );
    END;
    $$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION vibe_is_chat_admin(target_chat_id text) RETURNS boolean
    LANGUAGE plpgsql STABLE AS $$
    DECLARE
      uid uuid;
    BEGIN
      uid := vibe_current_user_id();
      IF uid IS NULL THEN
        RETURN false;
      END IF;

      RETURN EXISTS (
        SELECT 1
        FROM chat_participants cp
        WHERE cp.chat_id = target_chat_id
          AND cp.user_id = uid
          AND coalesce(cp.deleted, false) = false
          AND cp.role IN ('owner', 'admin')
      );
    END;
    $$;
    """)

    execute("DROP POLICY IF EXISTS messages_select_policy ON messages")
    execute("DROP POLICY IF EXISTS messages_insert_policy ON messages")
    execute("DROP POLICY IF EXISTS messages_update_policy ON messages")
    execute("DROP POLICY IF EXISTS messages_delete_policy ON messages")

    execute("""
    CREATE POLICY messages_select_policy ON messages
    FOR SELECT
    USING (vibe_is_chat_participant(chat_id))
    """)

    execute("""
    CREATE POLICY messages_insert_policy ON messages
    FOR INSERT
    WITH CHECK (
      vibe_is_chat_participant(chat_id)
      AND (
        from_id = vibe_current_user_id()
        OR from_id = '#{@agent_user_id}'::uuid
      )
    )
    """)

    execute("""
    CREATE POLICY messages_update_policy ON messages
    FOR UPDATE
    USING (vibe_is_chat_participant(chat_id))
    WITH CHECK (vibe_is_chat_participant(chat_id))
    """)

    execute("""
    CREATE POLICY messages_delete_policy ON messages
    FOR DELETE
    USING (
      from_id = vibe_current_user_id()
      OR vibe_is_chat_admin(chat_id)
    )
    """)

    execute("DROP POLICY IF EXISTS group_agents_select_policy ON group_agents")
    execute("DROP POLICY IF EXISTS group_agents_insert_policy ON group_agents")
    execute("DROP POLICY IF EXISTS group_agents_update_policy ON group_agents")
    execute("DROP POLICY IF EXISTS group_agents_delete_policy ON group_agents")

    execute("""
    CREATE POLICY group_agents_select_policy ON group_agents
    FOR SELECT
    USING (vibe_is_chat_participant(chat_id))
    """)

    execute("""
    CREATE POLICY group_agents_insert_policy ON group_agents
    FOR INSERT
    WITH CHECK (vibe_is_chat_admin(chat_id))
    """)

    execute("""
    CREATE POLICY group_agents_update_policy ON group_agents
    FOR UPDATE
    USING (vibe_is_chat_admin(chat_id))
    WITH CHECK (vibe_is_chat_admin(chat_id))
    """)

    execute("""
    CREATE POLICY group_agents_delete_policy ON group_agents
    FOR DELETE
    USING (vibe_is_chat_admin(chat_id))
    """)

    execute("DROP POLICY IF EXISTS group_agent_memory_select_policy ON group_agent_memory")
    execute("DROP POLICY IF EXISTS group_agent_memory_insert_policy ON group_agent_memory")
    execute("DROP POLICY IF EXISTS group_agent_memory_update_policy ON group_agent_memory")
    execute("DROP POLICY IF EXISTS group_agent_memory_delete_policy ON group_agent_memory")

    execute("""
    CREATE POLICY group_agent_memory_select_policy ON group_agent_memory
    FOR SELECT
    USING (vibe_is_chat_participant(chat_id))
    """)

    execute("""
    CREATE POLICY group_agent_memory_insert_policy ON group_agent_memory
    FOR INSERT
    WITH CHECK (vibe_is_chat_participant(chat_id))
    """)

    execute("""
    CREATE POLICY group_agent_memory_update_policy ON group_agent_memory
    FOR UPDATE
    USING (vibe_is_chat_participant(chat_id))
    WITH CHECK (vibe_is_chat_participant(chat_id))
    """)

    execute("""
    CREATE POLICY group_agent_memory_delete_policy ON group_agent_memory
    FOR DELETE
    USING (vibe_is_chat_participant(chat_id))
    """)
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION vibe_is_chat_participant(target_chat_id text) RETURNS boolean
    LANGUAGE plpgsql STABLE AS $$
    DECLARE
      uid uuid;
    BEGIN
      uid := vibe_current_user_id();
      IF uid IS NULL THEN
        RETURN true;
      END IF;

      RETURN EXISTS (
        SELECT 1
        FROM chat_participants cp
        WHERE cp.chat_id = target_chat_id
          AND cp.user_id = uid
          AND coalesce(cp.deleted, false) = false
      );
    END;
    $$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION vibe_is_chat_admin(target_chat_id text) RETURNS boolean
    LANGUAGE plpgsql STABLE AS $$
    DECLARE
      uid uuid;
    BEGIN
      uid := vibe_current_user_id();
      IF uid IS NULL THEN
        RETURN true;
      END IF;

      RETURN EXISTS (
        SELECT 1
        FROM chat_participants cp
        WHERE cp.chat_id = target_chat_id
          AND cp.user_id = uid
          AND coalesce(cp.deleted, false) = false
          AND cp.role IN ('owner', 'admin')
      );
    END;
    $$;
    """)

    execute("DROP POLICY IF EXISTS messages_select_policy ON messages")
    execute("DROP POLICY IF EXISTS messages_insert_policy ON messages")
    execute("DROP POLICY IF EXISTS messages_update_policy ON messages")
    execute("DROP POLICY IF EXISTS messages_delete_policy ON messages")

    execute("""
    CREATE POLICY messages_select_policy ON messages
    FOR SELECT
    USING (vibe_is_chat_participant(chat_id))
    """)

    execute("""
    CREATE POLICY messages_insert_policy ON messages
    FOR INSERT
    WITH CHECK (
      vibe_is_chat_participant(chat_id)
      AND (
        vibe_current_user_id() IS NULL
        OR from_id = vibe_current_user_id()
        OR from_id = '#{@agent_user_id}'::uuid
      )
    )
    """)

    execute("""
    CREATE POLICY messages_update_policy ON messages
    FOR UPDATE
    USING (
      vibe_current_user_id() IS NULL
      OR from_id = vibe_current_user_id()
    )
    WITH CHECK (
      vibe_current_user_id() IS NULL
      OR from_id = vibe_current_user_id()
    )
    """)

    execute("""
    CREATE POLICY messages_delete_policy ON messages
    FOR DELETE
    USING (
      vibe_current_user_id() IS NULL
      OR from_id = vibe_current_user_id()
      OR vibe_is_chat_admin(chat_id)
    )
    """)

    execute("DROP POLICY IF EXISTS group_agents_select_policy ON group_agents")
    execute("DROP POLICY IF EXISTS group_agents_insert_policy ON group_agents")
    execute("DROP POLICY IF EXISTS group_agents_update_policy ON group_agents")
    execute("DROP POLICY IF EXISTS group_agents_delete_policy ON group_agents")

    execute("""
    CREATE POLICY group_agents_select_policy ON group_agents
    FOR SELECT
    USING (vibe_is_chat_participant(chat_id))
    """)

    execute("""
    CREATE POLICY group_agents_insert_policy ON group_agents
    FOR INSERT
    WITH CHECK (
      vibe_current_user_id() IS NULL
      OR vibe_is_chat_admin(chat_id)
    )
    """)

    execute("""
    CREATE POLICY group_agents_update_policy ON group_agents
    FOR UPDATE
    USING (
      vibe_current_user_id() IS NULL
      OR vibe_is_chat_admin(chat_id)
    )
    WITH CHECK (
      vibe_current_user_id() IS NULL
      OR vibe_is_chat_admin(chat_id)
    )
    """)

    execute("""
    CREATE POLICY group_agents_delete_policy ON group_agents
    FOR DELETE
    USING (
      vibe_current_user_id() IS NULL
      OR vibe_is_chat_admin(chat_id)
    )
    """)

    execute("DROP POLICY IF EXISTS group_agent_memory_select_policy ON group_agent_memory")
    execute("DROP POLICY IF EXISTS group_agent_memory_insert_policy ON group_agent_memory")
    execute("DROP POLICY IF EXISTS group_agent_memory_update_policy ON group_agent_memory")
    execute("DROP POLICY IF EXISTS group_agent_memory_delete_policy ON group_agent_memory")

    execute("""
    CREATE POLICY group_agent_memory_select_policy ON group_agent_memory
    FOR SELECT
    USING (vibe_is_chat_participant(chat_id))
    """)

    execute("""
    CREATE POLICY group_agent_memory_insert_policy ON group_agent_memory
    FOR INSERT
    WITH CHECK (
      vibe_current_user_id() IS NULL
      OR vibe_is_chat_participant(chat_id)
    )
    """)

    execute("""
    CREATE POLICY group_agent_memory_update_policy ON group_agent_memory
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
    CREATE POLICY group_agent_memory_delete_policy ON group_agent_memory
    FOR DELETE
    USING (
      vibe_current_user_id() IS NULL
      OR vibe_is_chat_participant(chat_id)
    )
    """)
  end
end
