defmodule Vibe.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w[draft published disabled archived]
  @output_modes ~w[text media voice]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agents" do
    field :status, :string, default: "draft"
    field :display_name, :string
    field :system_prompt, :string, default: ""
    field :persona, :string
    field :avatar_url, :string
    field :welcome_message, :string
    field :enabled_tools, {:array, :string}, default: []
    field :output_modes, {:array, :string}, default: ["text"]
    field :voice_provider, :string
    field :voice_profile, :string
    field :callback_url, :string
    field :webhook_secret_hash, :string
    field :webhook_secret_encrypted, :string
    field :secret_hint, :string
    field :published_at, :utc_datetime
    field :last_invoked_at, :utc_datetime

    belongs_to :owner, Vibe.Accounts.User, foreign_key: :owner_user_id
    belongs_to :agent_user, Vibe.Accounts.User, foreign_key: :agent_user_id

    timestamps()
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :owner_user_id,
      :agent_user_id,
      :status,
      :display_name,
      :system_prompt,
      :persona,
      :avatar_url,
      :welcome_message,
      :enabled_tools,
      :output_modes,
      :voice_provider,
      :voice_profile,
      :callback_url,
      :webhook_secret_hash,
      :webhook_secret_encrypted,
      :secret_hint,
      :published_at,
      :last_invoked_at
    ])
    |> validate_required([
      :owner_user_id,
      :agent_user_id,
      :status,
      :display_name,
      :webhook_secret_hash,
      :secret_hint
    ])
    |> validate_length(:display_name, min: 1, max: 80)
    |> validate_inclusion(:status, @statuses)
    |> validate_change(:output_modes, fn :output_modes, modes ->
      invalid = Enum.reject(List.wrap(modes), &(&1 in @output_modes))
      if invalid == [], do: [], else: [output_modes: "contains invalid modes: #{Enum.join(invalid, ", ")}"]
    end)
    |> unique_constraint(:agent_user_id)
  end
end
