defmodule Vibe.AgentDeliveryEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_delivery_events" do
    field :event_type, :string
    field :target_url, :string
    field :request_body, :map, default: %{}
    field :response_code, :integer
    field :status, :string, default: "pending"
    field :attempt_count, :integer, default: 0
    field :last_error, :string

    belongs_to :agent, Vibe.Agent
    belongs_to :invocation, Vibe.AgentInvocation

    timestamps()
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :agent_id,
      :invocation_id,
      :event_type,
      :target_url,
      :request_body,
      :response_code,
      :status,
      :attempt_count,
      :last_error
    ])
    |> validate_required([:agent_id, :invocation_id, :event_type, :target_url, :request_body, :status])
  end
end
