defmodule Vibe.Chat do
  import Ecto.Query, warn: false
  require Logger
  alias Vibe.ChatHomeCache
  alias Vibe.Agent
  alias Vibe.Repo
  alias Vibe.RepoRLS
  alias Vibe.SupabaseStorage

  alias Vibe.Chat.{
    Room,
    Message,
    Participant,
    MessageRead,
    SavedMessage,
    ScheduledPost,
    PinnedMessage,
    AgentMessageCrypto
  }

  @agent_user_id "00000000-0000-0000-0000-000000000001"
  @home_preview_message_limit 1
  @history_default_limit 30
  @history_max_limit 100

  def save_message(attrs) do
    %SavedMessage{}
    |> SavedMessage.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing)
  end

  def unsave_message(user_id, original_message_id) do
    from(sm in SavedMessage,
      where: sm.user_id == ^user_id and sm.original_message_id == ^original_message_id
    )
    |> Repo.delete_all()
  end

  def list_saved_messages(user_id) do
    Repo.all(
      from(sm in SavedMessage,
        where: sm.user_id == ^user_id,
        order_by: [desc: sm.timestamp]
      )
    )
    |> Enum.map(&to_client_saved_message/1)
  end

  def is_participant?(chat_id, user_id) do
    Repo.exists?(
      from(p in Participant,
        where: p.chat_id == ^chat_id and p.user_id == ^user_id
      )
    )
  end

  def get_participant_ids(chat_id) do
    Repo.all(
      from(p in Participant,
        where: p.chat_id == ^chat_id,
        select: p.user_id
      )
    )
  end

  def get_participant_settings(chat_id, user_id) do
    Repo.one(from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id))
  end

  def get_all_participant_settings(chat_id) do
    Repo.all(from(p in Participant, where: p.chat_id == ^chat_id))
  end

  def list_chats(user_id) do
    loader = fn -> list_chats_uncached(user_id) end

    if is_binary(user_id) and String.trim(user_id) != "" do
      ChatHomeCache.fetch(user_id, loader)
    else
      loader.()
    end
  end

  defp list_chats_uncached(user_id) do
    result =
      RepoRLS.with_user(user_id, fn ->
        # Find all chats user is participating in (excluding deleted ones)
        user_chats_query =
          from(p in Participant,
            where: p.user_id == ^user_id and (is_nil(p.deleted) or p.deleted == false),
            select: {p.chat_id, p}
          )

        results = Repo.all(user_chats_query)
        chat_ids = Enum.map(results, fn {chat_id, _} -> chat_id end)

        # Batch-fetch all rooms in one query
        rooms =
          from(r in Room, where: r.id in ^chat_ids)
          |> Repo.all()
          |> Map.new(fn r -> {r.id, r} end)

        # Batch-fetch all friend participants with users preloaded in one query
        friend_participants =
          from(p in Participant,
            where: p.chat_id in ^chat_ids and p.user_id != ^user_id,
            preload: [:user]
          )
          |> Repo.all()
          |> Enum.group_by(& &1.chat_id)

        agent_friend_user_ids =
          friend_participants
          |> Map.values()
          |> List.flatten()
          |> Enum.filter(&(&1.user && &1.user.is_agent))
          |> Enum.map(& &1.user_id)
          |> Enum.uniq()

        agent_friends_by_user_id =
          if agent_friend_user_ids == [] do
            %{}
          else
            from(a in Agent,
              where: a.agent_user_id in ^agent_friend_user_ids,
              select: {a.agent_user_id, %{display_name: a.display_name, avatar_url: a.avatar_url}}
            )
            |> Repo.all()
            |> Map.new()
          end

        # Batch-fetch latest 15 messages per chat using a window function
        ranked_query =
          from(m in Message,
            where: m.chat_id in ^chat_ids,
            select: %{
              id: m.id,
              rnk: row_number() |> over(partition_by: m.chat_id, order_by: [desc: m.timestamp])
            }
          )

        top_message_ids =
          if chat_ids == [] do
            []
          else
            Repo.all(ranked_query)
            |> Enum.filter(&(&1.rnk <= @home_preview_message_limit))
            |> Enum.map(& &1.id)
          end

        last_messages_by_chat =
          if top_message_ids == [] do
            %{}
          else
            from(m in Message,
              where: m.id in ^top_message_ids,
              order_by: [asc: m.timestamp]
            )
            |> Repo.all()
            |> Enum.group_by(& &1.chat_id)
          end

        # Batch-fetch member counts for group/channel chats
        group_channel_ids =
          Enum.filter(chat_ids, fn id ->
            room = Map.get(rooms, id)
            room && room.type in ["group", "channel"]
          end)

        member_counts =
          if group_channel_ids != [] do
            from(p in Participant,
              where: p.chat_id in ^group_channel_ids,
              group_by: p.chat_id,
              select: {p.chat_id, count(p.id)}
            )
            |> Repo.all()
            |> Map.new()
          else
            %{}
          end

        group_members =
          if group_channel_ids != [] do
            from(p in Participant,
              where: p.chat_id in ^group_channel_ids,
              preload: [:user],
              order_by: [asc: p.inserted_at]
            )
            |> Repo.all()
            |> Enum.group_by(& &1.chat_id)
          else
            %{}
          end

        Enum.map(results, fn {chat_id, my_settings} ->
          room = Map.get(rooms, chat_id)
          friend_p = List.first(Map.get(friend_participants, chat_id, []))
          friend_agent = if(friend_p, do: Map.get(agent_friends_by_user_id, friend_p.user_id), else: nil)

          # Filter last message by cleared_at if applicable
          chat_messages = Map.get(last_messages_by_chat, chat_id, [])

          chat_messages =
            if my_settings.messages_cleared_at do
              cleared_at_ms =
                my_settings.messages_cleared_at
                |> DateTime.from_naive!("Etc/UTC")
                |> DateTime.to_unix(:millisecond)

              Enum.filter(chat_messages, &(&1.timestamp > cleared_at_ms))
            else
              chat_messages
            end

          room_type = if(room, do: room.type, else: "dm")

          members =
            if room_type in ["group", "channel"] do
              Map.get(group_members, chat_id, [])
              |> Enum.map(fn member ->
                %{
                  userId: member.user_id,
                  name: if(member.user, do: member.user.username, else: nil),
                  role: member.role || "member"
                }
              end)
            else
              nil
            end

          messages_for_client = Enum.map(chat_messages, &to_client_message/1)

          %{
            chatId: chat_id,
            type: room_type,
            name: if(room, do: room.name, else: nil),
            description: if(room, do: room.description, else: nil),
            avatarUrl: if(room, do: room.avatar_url, else: nil),
            creatorId: if(room, do: room.creator_id, else: nil),
            memberCount: Map.get(member_counts, chat_id),
            role: my_settings.role,
            friendId: if(friend_p, do: friend_p.user_id, else: nil),
            friendName:
              present_chat_friend_name(
                if(friend_p, do: friend_p.user, else: nil),
                friend_agent
              ),
            friendImage:
              present_chat_friend_image(
                if(friend_p, do: friend_p.user, else: nil),
                friend_agent
              ),
            members: members,
            messages: messages_for_client,
            unreadCount: 0,
            pinned: my_settings.pinned,
            muted: my_settings.muted
          }
        end)
      end)

    case result do
      chats when is_list(chats) ->
        chats

      {:error, reason} ->
        Logger.error("[Chat] list_chats failed user_id=#{user_id}: #{inspect(reason)}")
        []

      other ->
        Logger.error("[Chat] list_chats unexpected result user_id=#{user_id}: #{inspect(other)}")
        []
    end
  end

  defp present_chat_friend_name(user, agent_payload) do
    present_string(agent_payload && agent_payload.display_name) ||
      present_string(user && user.name) ||
      present_string(user && user.username)
  end

  defp present_chat_friend_image(user, agent_payload) do
    present_string(agent_payload && agent_payload.avatar_url) ||
      present_string(user && user.profile_image)
  end

  defp present_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present_string(_), do: nil

  def find_chat_between_users(u1, u2) do
    query =
      from(r in Room,
        join: p1 in Participant,
        on: p1.chat_id == r.id,
        join: p2 in Participant,
        on: p2.chat_id == r.id,
        where: r.type == "dm" and p1.user_id == ^u1 and p2.user_id == ^u2,
        select: r.id,
        limit: 1
      )

    Repo.one(query)
  end

  def ensure_dm_chat(user_id, peer_user_id) when is_binary(user_id) and is_binary(peer_user_id) do
    case find_chat_between_users(user_id, peer_user_id) do
      chat_id when is_binary(chat_id) ->
        status =
          case restore_if_deleted(chat_id, user_id) do
            :restored -> "restored"
            _ -> "existing"
          end

        {:ok, chat_id, status}

      nil ->
        chat_id = deterministic_dm_chat_id(user_id, peer_user_id)

        try do
          case create_chat(chat_id, [user_id, peer_user_id]) do
            {:ok, _room} ->
              {:ok, chat_id, "created"}

            {:error, reason} ->
              {:error, reason}

            other ->
              {:error, other}
          end
        rescue
          Ecto.ConstraintError ->
            status =
              case restore_if_deleted(chat_id, user_id) do
                :restored -> "restored"
                _ -> "existing"
              end

            {:ok, chat_id, status}
        end
    end
  end

  def get_chat(id) do
    Repo.get(Room, id) |> Repo.preload(:participants)
  end

  def create_chat(id, user_ids) do
    result =
      Repo.transaction(fn ->
        room = Repo.insert!(%Room{id: id, is_group: length(user_ids) > 2})

        Enum.each(user_ids, fn uid ->
          Repo.insert!(%Participant{chat_id: id, user_id: uid})
        end)

        room
      end)

    case result do
      {:ok, room} ->
        ChatHomeCache.invalidate_users(user_ids)
        {:ok, room}

      other ->
        other
    end
  end

  defp deterministic_dm_chat_id(u1, u2) do
    :crypto.hash(:sha256, Enum.sort([u1, u2]) |> Enum.join("|"))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  def add_message(attrs, opts \\ []) do
    acting_user_id =
      normalize_actor_id(Keyword.get(opts, :acting_user_id) || extract_from_id(attrs))

    from_id = normalize_actor_id(extract_from_id(attrs))

    cond do
      is_binary(acting_user_id) and is_binary(from_id) and acting_user_id != from_id and
          from_id != @agent_user_id ->
        {:error, :forbidden_sender}

      true ->
        result =
          RepoRLS.with_user(acting_user_id || from_id, fn ->
            %Message{}
            |> Message.changeset(attrs)
            |> Repo.insert()
          end)

        case result do
          {:ok, %Message{} = message} ->
            invalidate_chat_home_cache(message.chat_id)
            {:ok, message}

          other ->
            other
        end
    end
  end

  def get_message(chat_id, message_id, user_id \\ nil) do
    RepoRLS.with_user(user_id, fn ->
      with {:ok, message_uuid} <- Ecto.UUID.cast(message_id) do
        Repo.one(
          from(m in Message,
            where: m.chat_id == ^chat_id and m.id == ^message_uuid
          )
        )
      else
        _ -> nil
      end
    end)
  end

  def get_messages(chat_id, user_id \\ nil) do
    RepoRLS.with_user(user_id, fn ->
      Repo.all(
        from(m in Message,
          where: m.chat_id == ^chat_id,
          order_by: [asc: m.timestamp]
        )
      )
      |> Enum.map(&to_client_message/1)
    end)
  end

  def get_messages_for_user(chat_id, user_id) do
    RepoRLS.with_user(user_id, fn ->
      # Get user's cleared_at timestamp
      participant =
        Repo.one(
          from(p in Participant,
            where: p.chat_id == ^chat_id and p.user_id == ^user_id,
            select: p.messages_cleared_at
          )
        )

      query =
        from(m in Message,
          where: m.chat_id == ^chat_id,
          order_by: [asc: m.timestamp]
        )

      query =
        if participant do
          cleared_at_ms =
            participant
            |> DateTime.from_naive!("Etc/UTC")
            |> DateTime.to_unix(:millisecond)

          from(m in query, where: m.timestamp > ^cleared_at_ms)
        else
          query
        end

      Repo.all(query)
      |> Enum.map(&to_client_message/1)
    end)
  end

  def get_messages_for_user_page(chat_id, user_id, opts \\ []) do
    limit = normalize_history_limit(Keyword.get(opts, :limit))
    before = decode_history_cursor(Keyword.get(opts, :before))

    result =
      RepoRLS.with_user(user_id, fn ->
        participant =
          Repo.one(
            from(p in Participant,
              where: p.chat_id == ^chat_id and p.user_id == ^user_id,
              select: p.messages_cleared_at
            )
          )

        query =
          from(m in Message,
            where: m.chat_id == ^chat_id
          )

        query =
          if participant do
            cleared_at_ms =
              participant
              |> DateTime.from_naive!("Etc/UTC")
              |> DateTime.to_unix(:millisecond)

            from(m in query, where: m.timestamp > ^cleared_at_ms)
          else
            query
          end

        query =
          case before do
            %{timestamp: timestamp, id: id} ->
              from(m in query,
                where: m.timestamp < ^timestamp or (m.timestamp == ^timestamp and m.id < ^id)
              )

            _ ->
              query
          end

        Repo.all(
          from(m in query,
            order_by: [desc: m.timestamp, desc: m.id],
            limit: ^(limit + 1)
          )
        )
      end)

    case result do
      messages when is_list(messages) ->
        has_more = length(messages) > limit
        page_desc = Enum.take(messages, limit)

        next_cursor =
          if has_more do
            page_desc
            |> List.last()
            |> encode_history_cursor()
          else
            nil
          end

        %{
          messages: page_desc |> Enum.reverse() |> Enum.map(&to_client_message/1),
          next_cursor: next_cursor,
          has_more: has_more
        }

      {:error, reason} ->
        Logger.error(
          "[Chat] get_messages_for_user_page failed chat_id=#{chat_id} user_id=#{user_id}: #{inspect(reason)}"
        )

        %{messages: [], next_cursor: nil, has_more: false}

      other ->
        Logger.error(
          "[Chat] get_messages_for_user_page unexpected result chat_id=#{chat_id} user_id=#{user_id}: #{inspect(other)}"
        )

        %{messages: [], next_cursor: nil, has_more: false}
    end
  end

  def mark_read(message_id, reader_id) do
    result =
      RepoRLS.with_user(reader_id, fn ->
        # 1. Record the read receipt
        %MessageRead{}
        |> MessageRead.changeset(%{message_id: message_id, reader_id: reader_id})
        |> Repo.insert(on_conflict: :nothing)

        # 2. Update message status to 'read'
        from(m in Message, where: m.id == ^message_id)
        |> Repo.update_all(set: [status: "read"])
      end)

    invalidate_home_cache_for_message(message_id)
    result
  end

  def mark_delivered(message_id, user_id \\ nil) do
    result =
      RepoRLS.with_user(user_id, fn ->
        # Only update if status is 'sent' (don't overwrite 'read')
        from(m in Message, where: m.id == ^message_id and m.status == "sent")
        |> Repo.update_all(set: [status: "delivered"])
      end)

    invalidate_home_cache_for_message(message_id)
    result
  end

  def can_delete_message_for_everyone?(chat_id, user_id, from_id) do
    from_id == user_id ||
      Repo.exists?(
        from(p in Participant,
          where:
            p.chat_id == ^chat_id and
              p.user_id == ^user_id and
              p.role in ["owner", "admin"]
        )
      )
  end

  def delete_message(chat_id, message_id, user_id, for_everyone \\ true) do
    result =
      RepoRLS.with_user(user_id, fn ->
        if not is_participant?(chat_id, user_id) do
          {:error, :forbidden}
        else
          case Ecto.UUID.cast(message_id) do
            :error ->
              {:error, :invalid_id}

            {:ok, uuid} ->
              case Repo.one(from(m in Message, where: m.id == ^uuid and m.chat_id == ^chat_id)) do
                nil ->
                  {:error, :not_found}

                %Message{} = message ->
                  if for_everyone &&
                       not can_delete_message_for_everyone?(chat_id, user_id, message.from_id) do
                    {:error, :forbidden}
                  else
                    Repo.transaction(fn ->
                      from(r in MessageRead, where: r.message_id == ^uuid) |> Repo.delete_all()

                      from(pm in PinnedMessage, where: pm.message_id == ^uuid)
                      |> Repo.delete_all()

                      Repo.delete!(message)
                    end)

                    {:ok, message}
                  end
              end
          end
        end
      end)

    case result do
      {:ok, %Message{} = message} ->
        invalidate_chat_home_cache(chat_id)
        {:ok, message}

      other ->
        other
    end
  end

  def edit_message(chat_id, message_id, user_id, encrypted_content, edited_at \\ nil) do
    result =
      RepoRLS.with_user(user_id, fn ->
        if not is_participant?(chat_id, user_id) do
          {:error, :forbidden}
        else
          case Ecto.UUID.cast(message_id) do
            :error ->
              {:error, :invalid_id}

            {:ok, uuid} ->
              case Repo.one(from(m in Message, where: m.id == ^uuid and m.chat_id == ^chat_id)) do
                nil ->
                  {:error, :not_found}

                %Message{} = message ->
                  if message.from_id != user_id do
                    {:error, :forbidden}
                  else
                    next_timestamp =
                      cond do
                        is_integer(edited_at) and edited_at > 0 ->
                          max(message.timestamp || 0, edited_at)

                        true ->
                          message.timestamp
                      end

                    message
                    |> Ecto.Changeset.change(
                      encrypted_content: encrypted_content,
                      timestamp: next_timestamp
                    )
                    |> Repo.update()
                  end
              end
          end
        end
      end)

    case result do
      {:ok, %Message{} = message} ->
        invalidate_chat_home_cache(chat_id)
        {:ok, message}

      other ->
        other
    end
  end

  def list_pinned_messages(chat_id, user_id) do
    RepoRLS.with_user(user_id, fn ->
      Repo.all(
        from(pm in PinnedMessage,
          join: m in Message,
          on: pm.message_id == m.id,
          where: pm.chat_id == ^chat_id and pm.user_id == ^user_id,
          order_by: [desc: pm.inserted_at],
          select: %{
            messageId: pm.message_id,
            chatId: pm.chat_id,
            pinnedAt: pm.inserted_at,
            timestamp: m.timestamp
          }
        )
      )
    end)
  end

  def set_message_pin(chat_id, message_id, user_id, pinned \\ true) do
    result =
      RepoRLS.with_user(user_id, fn ->
        if not is_participant?(chat_id, user_id) do
          {:error, :forbidden}
        else
          case Ecto.UUID.cast(message_id) do
            :error ->
              {:error, :invalid_id}

            {:ok, uuid} ->
              if pinned do
                case Repo.one(from(m in Message, where: m.id == ^uuid and m.chat_id == ^chat_id)) do
                  nil ->
                    {:error, :not_found}

                  _message ->
                    changeset =
                      %PinnedMessage{}
                      |> PinnedMessage.changeset(%{
                        user_id: user_id,
                        chat_id: chat_id,
                        message_id: uuid
                      })

                    case Repo.insert(changeset,
                           on_conflict: :nothing,
                           conflict_target: [:user_id, :chat_id, :message_id]
                         ) do
                      {:ok, pin} ->
                        {:ok, pin}

                      {:error, changeset} ->
                        {:error, changeset}
                    end
                end
              else
                from(pm in PinnedMessage,
                  where:
                    pm.user_id == ^user_id and pm.chat_id == ^chat_id and pm.message_id == ^uuid
                )
                |> Repo.delete_all()

                {:ok, :unpinned}
              end
          end
        end
      end)

    case result do
      {:ok, value} ->
        ChatHomeCache.invalidate_user(user_id)
        {:ok, value}

      other ->
        other
    end
  end

  @doc """
  If users have pinned an older agent-generated file message in this chat,
  move their pin to the newest agent file message.
  """
  def refresh_pinned_agent_file(chat_id, new_message_id) do
    with {:ok, new_uuid} <- Ecto.UUID.cast(new_message_id) do
      Repo.transaction(fn ->
        pinned_user_ids =
          Repo.all(
            from(pm in PinnedMessage,
              join: m in Message,
              on: m.id == pm.message_id,
              where:
                pm.chat_id == ^chat_id and
                  m.chat_id == ^chat_id and
                  m.from_id == ^@agent_user_id and
                  m.type == "file",
              select: pm.user_id,
              distinct: true
            )
          )

        if pinned_user_ids == [] do
          0
        else
          from(pm in PinnedMessage,
            join: m in Message,
            on: m.id == pm.message_id,
            where:
              pm.chat_id == ^chat_id and
                m.chat_id == ^chat_id and
                m.from_id == ^@agent_user_id and
                m.type == "file"
          )
          |> Repo.delete_all()

          Enum.each(pinned_user_ids, fn pinned_user_id ->
            %PinnedMessage{}
            |> PinnedMessage.changeset(%{
              user_id: pinned_user_id,
              chat_id: chat_id,
              message_id: new_uuid
            })
            |> Repo.insert(
              on_conflict: :nothing,
              conflict_target: [:user_id, :chat_id, :message_id]
            )
          end)

          length(pinned_user_ids)
        end
      end)
      |> case do
        {:ok, updated_count} -> {:ok, updated_count}
        {:error, reason} -> {:error, reason}
      end
    else
      :error ->
        {:error, :invalid_message_id}
    end
  end

  def set_muted(chat_id, user_id, muted) do
    result =
      from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
      |> Repo.update_all(set: [muted: muted])

    ChatHomeCache.invalidate_user(user_id)
    result
  end

  def set_pinned(chat_id, user_id, pinned) do
    result =
      from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
      |> Repo.update_all(set: [pinned: pinned])

    ChatHomeCache.invalidate_user(user_id)
    result
  end

  def set_marked_unread(chat_id, user_id, marked) do
    result =
      from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
      |> Repo.update_all(set: [marked_unread: marked])

    ChatHomeCache.invalidate_user(user_id)
    result
  end

  def delete_chat(chat_id, user_id) do
    # Instead of deleting the chat, we mark the participant as deleted
    # This way the other user can still see the chat
    case from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
         |> Repo.update_all(set: [deleted: true, messages_cleared_at: NaiveDateTime.utc_now()]) do
      {1, _} ->
        ChatHomeCache.invalidate_user(user_id)
        {:ok, :deleted}

      {0, _} ->
        {:error, "Chat not found"}

      _ ->
        {:error, "Failed to delete"}
    end
  end

  def restore_if_deleted(chat_id, user_id) do
    # Check if this user has deleted the chat
    participant =
      Repo.one(
        from(p in Participant,
          where: p.chat_id == ^chat_id and p.user_id == ^user_id
        )
      )

    cond do
      is_nil(participant) ->
        # No participant record - shouldn't happen but treat as not deleted
        :not_deleted

      participant.deleted == true ->
        # Was deleted - restore it
        from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
        |> Repo.update_all(set: [deleted: false])

        ChatHomeCache.invalidate_user(user_id)
        :restored

      true ->
        # Not deleted
        :not_deleted
    end
  end

  # ── Groups ──────────────────────────────────────────────────────

  def create_group(creator_id, name, member_ids) do
    id = Ecto.UUID.generate() |> String.slice(0, 12)
    all_member_ids = Enum.uniq([creator_id | member_ids])

    result =
      Repo.transaction(fn ->
        room =
          Repo.insert!(%Room{
            id: id,
            is_group: true,
            type: "group",
            name: name,
            creator_id: creator_id
          })

        Enum.each(all_member_ids, fn uid ->
          role = if uid == creator_id, do: "owner", else: "member"
          Repo.insert!(%Participant{chat_id: id, user_id: uid, role: role})
        end)

        room
      end)

    case result do
      {:ok, room} ->
        ChatHomeCache.invalidate_users(all_member_ids)
        {:ok, room}

      other ->
        other
    end
  end

  def add_member(chat_id, user_id, role \\ "member") do
    result =
      %Participant{}
      |> Participant.changeset(%{chat_id: chat_id, user_id: user_id, role: role})
      |> Repo.insert(on_conflict: :nothing)

    invalidate_chat_home_cache(chat_id)
    ChatHomeCache.invalidate_user(user_id)
    result
  end

  def remove_member(chat_id, user_id) do
    result =
      from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
      |> Repo.delete_all()

    invalidate_chat_home_cache(chat_id)
    ChatHomeCache.invalidate_user(user_id)
    result
  end

  # ── Channels ────────────────────────────────────────────────────

  def create_channel(creator_id, name, description \\ nil) do
    id = Ecto.UUID.generate() |> String.slice(0, 12)

    result =
      Repo.transaction(fn ->
        room =
          Repo.insert!(%Room{
            id: id,
            is_group: false,
            type: "channel",
            name: name,
            description: description,
            creator_id: creator_id
          })

        Repo.insert!(%Participant{chat_id: id, user_id: creator_id, role: "owner"})

        room
      end)

    case result do
      {:ok, room} ->
        ChatHomeCache.invalidate_user(creator_id)
        {:ok, room}

      other ->
        other
    end
  end

  def join_channel(channel_id, user_id) do
    # Verify it's a channel
    case Repo.get(Room, channel_id) do
      %Room{type: "channel"} ->
        result =
          %Participant{}
          |> Participant.changeset(%{chat_id: channel_id, user_id: user_id, role: "subscriber"})
          |> Repo.insert(on_conflict: :nothing)

        invalidate_chat_home_cache(channel_id)
        ChatHomeCache.invalidate_user(user_id)
        result

      _ ->
        {:error, "Not a channel"}
    end
  end

  def leave_channel(channel_id, user_id) do
    # Don't allow owner to leave
    case Repo.one(
           from(p in Participant,
             where: p.chat_id == ^channel_id and p.user_id == ^user_id
           )
         ) do
      %Participant{role: "owner"} ->
        {:error, "Owner cannot leave channel"}

      %Participant{} = participant ->
        result = Repo.delete(participant)
        invalidate_chat_home_cache(channel_id)
        ChatHomeCache.invalidate_user(user_id)
        result

      nil ->
        {:error, "Not a member"}
    end
  end

  def list_channels do
    Repo.all(
      from(r in Room,
        where: r.type == "channel",
        order_by: [desc: r.inserted_at],
        preload: [:creator]
      )
    )
    |> Enum.map(fn room ->
      subscriber_count =
        Repo.aggregate(
          from(p in Participant, where: p.chat_id == ^room.id),
          :count
        )

      %{
        id: room.id,
        name: room.name,
        description: room.description,
        avatar_url: room.avatar_url,
        creator_id: room.creator_id,
        creator_name: if(room.creator, do: room.creator.username, else: nil),
        subscriber_count: subscriber_count,
        created_at: room.inserted_at
      }
    end)
  end

  def get_channel_analytics(channel_id, user_id \\ nil) do
    RepoRLS.with_user(user_id, fn ->
      subscriber_count =
        Repo.aggregate(
          from(p in Participant, where: p.chat_id == ^channel_id),
          :count
        )

      message_count =
        Repo.aggregate(
          from(m in Message, where: m.chat_id == ^channel_id),
          :count
        )

      # Recent subscribers (last 7 days)
      week_ago = DateTime.utc_now() |> DateTime.add(-7, :day)

      recent_joins =
        Repo.aggregate(
          from(p in Participant,
            where: p.chat_id == ^channel_id and p.inserted_at >= ^week_ago
          ),
          :count
        )

      %{
        subscriber_count: subscriber_count,
        message_count: message_count,
        recent_joins_7d: recent_joins
      }
    end)
  end

  # ── Permissions ─────────────────────────────────────────────────

  def can_send?(chat_id, user_id) do
    case Repo.get(Room, chat_id) do
      %Room{type: "channel"} ->
        # Only owner/admin can send in channels
        Repo.exists?(
          from(p in Participant,
            where:
              p.chat_id == ^chat_id and p.user_id == ^user_id and
                p.role in ["owner", "admin"]
          )
        )

      %Room{type: type} when type in ["dm", "group"] ->
        # All participants can send in DMs and groups
        is_participant?(chat_id, user_id)

      nil ->
        false
    end
  end

  def get_user_role(chat_id, user_id) do
    Repo.one(
      from(p in Participant,
        where: p.chat_id == ^chat_id and p.user_id == ^user_id,
        select: p.role
      )
    )
  end

  def get_room_type(chat_id) do
    Repo.one(from(r in Room, where: r.id == ^chat_id, select: r.type))
  end

  def get_user_channels(user_id) do
    Repo.all(
      from(p in Participant,
        join: r in Room,
        on: r.id == p.chat_id,
        where: p.user_id == ^user_id and r.type == "channel" and p.role == "owner",
        select: %{id: r.id, name: r.name}
      )
    )
  end

  # ── Scheduled Posts ─────────────────────────────────────────────

  def create_scheduled_post(attrs) do
    %ScheduledPost{}
    |> ScheduledPost.changeset(attrs)
    |> Repo.insert()
  end

  def list_scheduled_posts(channel_id) do
    Repo.all(
      from(sp in ScheduledPost,
        where: sp.channel_id == ^channel_id and sp.status == "pending",
        order_by: [asc: sp.scheduled_at]
      )
    )
  end

  def get_scheduled_post(id) do
    Repo.get(ScheduledPost, id)
  end

  def mark_post_as_posted(post_id) do
    from(sp in ScheduledPost, where: sp.id == ^post_id)
    |> Repo.update_all(set: [status: "posted", posted_at: DateTime.utc_now()])
  end

  def cancel_scheduled_post(post_id, user_id) do
    case Repo.get(ScheduledPost, post_id) do
      %ScheduledPost{user_id: ^user_id, status: "pending"} = post ->
        post
        |> ScheduledPost.changeset(%{status: "cancelled"})
        |> Repo.update()

      %ScheduledPost{} ->
        {:error, "Unauthorized or already posted"}

      nil ->
        {:error, "Not found"}
    end
  end

  defp extract_from_id(attrs) when is_map(attrs) do
    attrs[:from_id] || attrs["from_id"] || attrs[:fromId] || attrs["fromId"]
  end

  defp extract_from_id(_), do: nil

  defp normalize_actor_id(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_actor_id(_), do: nil

  defp to_client_message(nil), do: nil

  defp to_client_message(%Message{} = message) do
    case agent_message_meta(message) do
      nil ->
        base_message_map(message)

      meta ->
        plain_text = AgentMessageCrypto.decrypt_from_storage(message.encrypted_content || "")
        base = base_message_map(message)

        Map.merge(base, %{
          encrypted_content: "",
          plaintext: plain_text,
          plain_content: plain_text,
          is_agent_message: true,
          agent_name: meta.agent_name,
          agent_id: meta.agent_id
        })
    end
  end

  defp to_client_message(other), do: other

  defp to_client_saved_message(%SavedMessage{} = message) do
    %{
      id: message.id,
      user_id: message.user_id,
      original_message_id: message.original_message_id,
      chat_id: message.chat_id,
      from_id: message.from_id,
      encrypted_content: message.encrypted_content,
      content: message.content,
      type: message.type,
      media_url: rewrite_media_url(message.media_url),
      timestamp: message.timestamp,
      extra: message.extra,
      inserted_at: message.inserted_at
    }
  end

  defp agent_message_meta(%Message{} = message) do
    metadata = message.metadata || %{}

    cond do
      legacy_group_agent_id?(message.from_id) ->
        %{agent_name: "Vibe AI", agent_id: nil}

      metadata["isAgentMessage"] == true or metadata["is_agent_message"] == true ->
        %{
          agent_name: metadata["agentName"] || metadata["agent_name"] || "Vibe Agent",
          agent_id: metadata["agentId"] || metadata["agent_id"]
        }

      true ->
        nil
    end
  end

  defp legacy_group_agent_id?(from_id) do
    case {Ecto.UUID.cast(from_id), Ecto.UUID.cast(@agent_user_id)} do
      {{:ok, a}, {:ok, b}} -> a == b
      _ -> false
    end
  end

  defp base_message_map(%Message{} = message) do
    %{
      id: message.id,
      chat_id: message.chat_id,
      from_id: message.from_id,
      timestamp: message.timestamp,
      type: message.type,
      encrypted_content: message.encrypted_content,
      status: message.status,
      media_url: rewrite_media_url(message.media_url),
      metadata: message.metadata || %{},
      reply_to_id: message.reply_to_id
    }
  end

  defp rewrite_media_url(url), do: SupabaseStorage.rewrite_public_url(url)

  defp invalidate_chat_home_cache(chat_id) when is_binary(chat_id) do
    participant_ids =
      Repo.all(
        from(p in Participant,
          where: p.chat_id == ^chat_id,
          select: p.user_id
        )
      )

    ChatHomeCache.invalidate_users(participant_ids)
    :ok
  end

  defp invalidate_chat_home_cache(_chat_id), do: :ok

  defp invalidate_home_cache_for_message(message_id) when is_binary(message_id) do
    case Repo.one(from(m in Message, where: m.id == ^message_id, select: m.chat_id)) do
      chat_id when is_binary(chat_id) -> invalidate_chat_home_cache(chat_id)
      _ -> :ok
    end
  end

  defp invalidate_home_cache_for_message(_message_id), do: :ok

  defp normalize_history_limit(limit) when is_integer(limit),
    do: limit |> max(1) |> min(@history_max_limit)

  defp normalize_history_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, _rest} -> normalize_history_limit(parsed)
      :error -> @history_default_limit
    end
  end

  defp normalize_history_limit(_limit), do: @history_default_limit

  defp encode_history_cursor(%Message{} = message) do
    Jason.encode!(%{timestamp: message.timestamp || 0, id: message.id})
    |> Base.url_encode64(padding: false)
  end

  defp encode_history_cursor(_message), do: nil

  defp decode_history_cursor(nil), do: nil
  defp decode_history_cursor(""), do: nil

  defp decode_history_cursor(cursor) when is_binary(cursor) do
    with {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"timestamp" => timestamp, "id" => id}} <- Jason.decode(raw),
         ts when is_integer(ts) <- normalize_cursor_timestamp(timestamp),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      %{timestamp: ts, id: uuid}
    else
      _ -> nil
    end
  end

  defp decode_history_cursor(_cursor), do: nil

  defp normalize_cursor_timestamp(value) when is_integer(value), do: value

  defp normalize_cursor_timestamp(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp normalize_cursor_timestamp(_value), do: nil
end
