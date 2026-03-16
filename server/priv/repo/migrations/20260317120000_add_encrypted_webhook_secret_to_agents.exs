defmodule Vibe.Repo.Migrations.AddEncryptedWebhookSecretToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :webhook_secret_encrypted, :text
    end
  end
end
