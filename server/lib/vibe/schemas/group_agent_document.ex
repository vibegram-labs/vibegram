defmodule Vibe.Chat.GroupAgentDocument do
  @moduledoc """
  Stores group-agent generated document versions per chat.
  Exactly one row per chat is marked as current; edits create new versions.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Vibe.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_agent_documents" do
    field :chat_id, :string
    field :title, :string
    field :format, :string, default: "csv"
    field :relative_url, :string
    field :file_url, :string
    field :columns, {:array, :string}, default: []
    field :row_count, :integer, default: 0
    field :metadata, :map, default: %{}
    field :version, :integer
    field :is_current, :boolean, default: false
    field :change_type, :string, default: "create"
    field :previous_document_id, :binary_id
    field :created_by_user_id, :binary_id

    timestamps()
  end

  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :chat_id,
      :title,
      :format,
      :relative_url,
      :file_url,
      :columns,
      :row_count,
      :metadata,
      :version,
      :is_current,
      :change_type,
      :previous_document_id,
      :created_by_user_id
    ])
    |> validate_required([:chat_id, :title, :format, :relative_url, :file_url, :version, :change_type])
    |> validate_inclusion(:change_type, ["create", "edit", "revert"])
    |> validate_number(:row_count, greater_than_or_equal_to: 0)
    |> validate_number(:version, greater_than: 0)
    |> unique_constraint([:chat_id, :version], name: :group_agent_documents_chat_id_version_index)
    |> unique_constraint(:chat_id, name: :group_agent_documents_one_current_idx)
  end

  def get_current(chat_id) do
    Repo.one(from d in __MODULE__, where: d.chat_id == ^chat_id and d.is_current == true)
  end

  def get_by_id(id) when is_binary(id), do: Repo.get(__MODULE__, id)
  def get_by_id(_), do: nil

  def get_by_blob_key(blob_key) when is_binary(blob_key) do
    normalized = blob_key |> String.trim()

    if normalized == "" do
      nil
    else
      Repo.one(
        from d in __MODULE__,
          where: fragment("?->>'blob_key' = ?", d.metadata, ^normalized),
          order_by: [desc: d.inserted_at],
          limit: 1
      )
    end
  end

  def get_by_blob_key(_), do: nil

  def get_previous(chat_id, current_version) when is_integer(current_version) do
    Repo.one(
      from d in __MODULE__,
        where: d.chat_id == ^chat_id and d.version < ^current_version,
        order_by: [desc: d.version],
        limit: 1
    )
  end

  def get_previous(_chat_id, _version), do: nil

  def list_recent(chat_id, limit \\ 20) do
    safe_limit = if is_integer(limit) and limit > 0, do: limit, else: 20

    Repo.all(
      from d in __MODULE__,
        where: d.chat_id == ^chat_id,
        order_by: [desc: d.inserted_at],
        limit: ^safe_limit
    )
  end

  def create_new_version(chat_id, attrs) when is_binary(chat_id) and is_map(attrs) do
    Repo.transaction(fn ->
      current =
        Repo.one(
          from d in __MODULE__,
            where: d.chat_id == ^chat_id and d.is_current == true,
            lock: "FOR UPDATE"
        )

      if current do
        from(d in __MODULE__, where: d.id == ^current.id)
        |> Repo.update_all(set: [is_current: false])
      end

      version = if current, do: current.version + 1, else: 1

      payload =
        attrs
        |> normalize_attrs(chat_id, version, current)

      case %__MODULE__{} |> changeset(payload) |> Repo.insert() do
        {:ok, inserted} -> inserted
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, doc} -> {:ok, doc}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_new_version(_chat_id, _attrs), do: {:error, :invalid_args}

  def clear_by_chat(chat_id) do
    from(d in __MODULE__, where: d.chat_id == ^chat_id)
    |> Repo.delete_all()
  end

  defp normalize_attrs(attrs, chat_id, version, current) do
    previous_id =
      Map.get(attrs, :previous_document_id) ||
        Map.get(attrs, "previous_document_id") ||
        (if current, do: current.id, else: nil)

    %{
      chat_id: chat_id,
      title: map_get(attrs, :title, "Document"),
      format: map_get(attrs, :format, "csv"),
      relative_url: map_get(attrs, :relative_url, ""),
      file_url: map_get(attrs, :file_url, ""),
      columns: map_get(attrs, :columns, []),
      row_count: map_get(attrs, :row_count, 0),
      metadata: map_get(attrs, :metadata, %{}),
      version: version,
      is_current: true,
      change_type: map_get(attrs, :change_type, "edit"),
      previous_document_id: previous_id,
      created_by_user_id: map_get(attrs, :created_by_user_id, nil)
    }
  end

  defp map_get(attrs, key, fallback) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key)) || fallback
  end
end
