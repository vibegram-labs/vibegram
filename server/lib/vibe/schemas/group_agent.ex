defmodule Vibe.Chat.GroupAgent do
  @moduledoc """
  Schema for AI agent configuration attached to a group or channel.
  Each group/channel can have at most one agent.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Vibe.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_agents" do
    field :chat_id, :string
    field :enabled, :boolean, default: true
    field :name, :string, default: "Vibe AI"
    field :system_prompt, :string
    field :avatar_url, :string
    field :created_by, :binary_id

    timestamps()
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:chat_id, :enabled, :name, :system_prompt, :avatar_url, :created_by])
    |> validate_required([:chat_id, :system_prompt])
    |> validate_length(:name, max: 50)
    |> validate_length(:system_prompt, max: 4000)
    |> unique_constraint(:chat_id)
  end

  # ── CRUD ──

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def get_by_chat(chat_id) do
    Repo.one(from a in __MODULE__, where: a.chat_id == ^chat_id)
  end

  def get_enabled_by_chat(chat_id) do
    Repo.one(from a in __MODULE__, where: a.chat_id == ^chat_id and a.enabled == true)
  end

  def update(agent, attrs) do
    agent
    |> changeset(attrs)
    |> Repo.update()
  end

  def delete(agent) do
    Repo.delete(agent)
  end

  def delete_by_chat(chat_id) do
    from(a in __MODULE__, where: a.chat_id == ^chat_id)
    |> Repo.delete_all()
  end
end
