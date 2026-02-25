defmodule Vibe.Chat.GroupAgentMemory do
  @moduledoc """
  Schema for group agent conversation memory.
  Stores recent messages and a compacted summary for long-running context.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Vibe.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_agent_memory" do
    field :chat_id, :string
    field :messages, {:array, :map}, default: []
    field :summary, :string
    field :total_messages_processed, :integer, default: 0
    field :last_compacted_at, :naive_datetime

    timestamps()
  end

  def changeset(memory, attrs) do
    memory
    |> cast(attrs, [:chat_id, :messages, :summary, :total_messages_processed, :last_compacted_at])
    |> validate_required([:chat_id])
    |> unique_constraint(:chat_id)
  end

  # ── CRUD ──

  def get_or_create(chat_id) do
    case Repo.one(from m in __MODULE__, where: m.chat_id == ^chat_id) do
      nil ->
        %__MODULE__{}
        |> changeset(%{chat_id: chat_id, messages: [], total_messages_processed: 0})
        |> Repo.insert()

      memory ->
        {:ok, memory}
    end
  end

  def append_message(chat_id, message) do
    case get_or_create(chat_id) do
      {:ok, memory} ->
        msg = Map.merge(%{
          "id" => Ecto.UUID.generate(),
          "timestamp" => :os.system_time(:millisecond)
        }, message)

        new_messages = memory.messages ++ [msg]
        new_total = memory.total_messages_processed + 1

        memory
        |> changeset(%{messages: new_messages, total_messages_processed: new_total})
        |> Repo.update()

      error ->
        error
    end
  end

  def update_after_compaction(memory, summary, remaining_messages) do
    memory
    |> changeset(%{
      messages: remaining_messages,
      summary: summary,
      last_compacted_at: NaiveDateTime.utc_now()
    })
    |> Repo.update()
  end

  def clear(chat_id) do
    case Repo.one(from m in __MODULE__, where: m.chat_id == ^chat_id) do
      nil -> {:ok, nil}
      memory ->
        memory
        |> changeset(%{messages: [], summary: nil, total_messages_processed: 0, last_compacted_at: nil})
        |> Repo.update()
    end
  end

  def delete_by_chat(chat_id) do
    from(m in __MODULE__, where: m.chat_id == ^chat_id)
    |> Repo.delete_all()
  end
end
