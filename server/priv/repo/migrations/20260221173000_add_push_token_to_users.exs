defmodule Vibe.Repo.Migrations.AddPushTokenToUsers do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE users
    ADD COLUMN IF NOT EXISTS push_token text
    """)
  end

  def down do
    execute("""
    ALTER TABLE users
    DROP COLUMN IF EXISTS push_token
    """)
  end
end
