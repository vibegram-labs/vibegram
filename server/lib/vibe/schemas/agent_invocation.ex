defmodule Vibe.AgentInvocation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_invocations" do
    field :source, :string
    field :event_id, :string
    field :vibe_chat_id, :string
    field :external_user_id, :string
    field :request_payload, :map, default: %{}
    field :response_payload, :map, default: %{}
    field :status, :string, default: "completed"
    field :error, :string

    belongs_to :agent, Vibe.Agent

    timestamps()
  end

  def changeset(invocation, attrs) do
    invocation
    |> cast(attrs, [
      :agent_id,
      :source,
      :event_id,
      :vibe_chat_id,
      :external_user_id,
      :request_payload,
      :response_payload,
      :status,
      :error
    ])
    |> validate_required([:agent_id, :source, :request_payload, :response_payload, :status])
    |> unique_constraint(:event_id, name: :agent_invocations_agent_id_event_id_index)
  end
end
