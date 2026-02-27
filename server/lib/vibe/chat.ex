defmodule Vibe.Chat do
  import Ecto.Query, warn: false
  require Logger
  alias Vibe.Repo
  alias Vibe.RepoRLS
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

  def save_message(attrs) do
    %SavedMessage{}
    |> SavedMessage.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing)
  end

  def unsave_message(user_id, original_message_id) do
    from(sm in SavedMessage, where: sm.user_id == ^user_id and sm.original_message_id == ^original_message_id)
    |> Repo.delete_all()
  end

  def list_saved_messages(user_id) do
    Repo.all(from sm in SavedMessage,
             where: sm.user_id == ^user_id,
             order_by: [desc: sm.timestamp])
  end

  def is_participant?(chat_id, user_id) do
    Repo.exists?(from p in Participant,
                 where: p.chat_id == ^chat_id and p.user_id == ^user_id)
  end

  def get_participant_ids(chat_id) do
    Repo.all(from p in Participant,
             where: p.chat_id == ^chat_id,
             select: p.user_id)
  end

  def get_participant_settings(chat_id, user_id) do
    Repo.one(from p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
  end

  def get_all_participant_settings(chat_id) do
    Repo.all(from p in Participant, where: p.chat_id == ^chat_id)
  end

  def list_chats(user_id) do
    result =
      RepoRLS.with_user(user_id, fn ->
      # Find all chats user is participating in (excluding deleted ones)
      user_chats_query =
        from p in Participant,
          where: p.user_id == ^user_id and (is_nil(p.deleted) or p.deleted == false),
          select: {p.chat_id, p}

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

      # Batch-fetch latest message per chat using a window function
      last_messages =
        from(m in Message,
          where: m.chat_id in ^chat_ids,
          distinct: m.chat_id,
          order_by: [asc: m.chat_id, desc: m.timestamp]
        )
        |> Repo.all()
        |> Map.new(fn m -> {m.chat_id, m} end)

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

        # Filter last message by cleared_at if applicable
        last_msg = Map.get(last_messages, chat_id)

        last_msg =
          if last_msg && my_settings.messages_cleared_at do
            cleared_at_ms =
              my_settings.messages_cleared_at
              |> DateTime.from_naive!("Etc/UTC")
              |> DateTime.to_unix(:millisecond)

            if last_msg.timestamp > cleared_at_ms, do: last_msg, else: nil
          else
            last_msg
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

        last_msg_for_client = to_client_message(last_msg)

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
          friendName: if(friend_p && friend_p.user, do: friend_p.user.username, else: nil),
          friendImage: if(friend_p && friend_p.user, do: friend_p.user.profile_image, else: nil),
          members: members,
          messages: if(last_msg_for_client, do: [last_msg_for_client], else: []),
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

  def find_chat_between_users(u1, u2) do
    # Find a chat ID that has both participants
    # This is a bit tricky in pure Ecto without subqueries or direct SQL if schema is normalized strictly
    # Simpler: Get u1 chats, check if u2 is in them.

    query = from p1 in Participant,
            join: p2 in Participant, on: p1.chat_id == p2.chat_id,
            where: p1.user_id == ^u1 and p2.user_id == ^u2,
            select: p1.chat_id,
            limit: 1

    Repo.one(query)
  end

  def get_chat(id) do
    Repo.get(Room, id) |> Repo.preload(:participants)
  end

  def create_chat(id, user_ids) do
    Repo.transaction(fn ->
      room = Repo.insert!(%Room{id: id, is_group: length(user_ids) > 2})

      Enum.each(user_ids, fn uid ->
        Repo.insert!(%Participant{chat_id: id, user_id: uid})
      end)

      room
    end)
  end

  def add_message(attrs, opts \\ []) do
    acting_user_id =
      normalize_actor_id(
        Keyword.get(opts, :acting_user_id) || extract_from_id(attrs)
      )

    from_id = normalize_actor_id(extract_from_id(attrs))

    cond do
      is_binary(acting_user_id) and is_binary(from_id) and acting_user_id != from_id and
          from_id != @agent_user_id ->
        {:error, :forbidden_sender}

      true ->
        RepoRLS.with_user(acting_user_id || from_id, fn ->
          %Message{}
          |> Message.changeset(attrs)
          |> Repo.insert()
        end)
    end
  end

  def get_message(chat_id, message_id, user_id \\ nil) do
    RepoRLS.with_user(user_id, fn ->
      with {:ok, message_uuid} <- Ecto.UUID.cast(message_id) do
        Repo.one(
          from m in Message,
            where: m.chat_id == ^chat_id and m.id == ^message_uuid
        )
      else
        _ -> nil
      end
    end)
  end

  def get_messages(chat_id, user_id \\ nil) do
    RepoRLS.with_user(user_id, fn ->
      Repo.all(
        from m in Message,
          where: m.chat_id == ^chat_id,
          order_by: [asc: m.timestamp],
          preload: [:reads]
      )
      |> Enum.map(&to_client_message/1)
    end)
  end

  def get_messages_for_user(chat_id, user_id) do
    RepoRLS.with_user(user_id, fn ->
      # Get user's cleared_at timestamp
      participant =
        Repo.one(
          from p in Participant,
            where: p.chat_id == ^chat_id and p.user_id == ^user_id,
            select: p.messages_cleared_at
        )

      query =
        from m in Message,
          where: m.chat_id == ^chat_id,
          order_by: [asc: m.timestamp],
          preload: [:reads]

      query =
        if participant do
          cleared_at_ms =
            participant
            |> DateTime.from_naive!("Etc/UTC")
            |> DateTime.to_unix(:millisecond)

          from m in query, where: m.timestamp > ^cleared_at_ms
        else
          query
        end

      Repo.all(query)
      |> Enum.map(&to_client_message/1)
    end)
  end

  def mark_read(message_id, reader_id) do
    RepoRLS.with_user(reader_id, fn ->
      # 1. Record the read receipt
      %MessageRead{}
      |> MessageRead.changeset(%{message_id: message_id, reader_id: reader_id})
      |> Repo.insert(on_conflict: :nothing)

      # 2. Update message status to 'read'
      from(m in Message, where: m.id == ^message_id)
      |> Repo.update_all(set: [status: "read"])
    end)
  end

  def mark_delivered(message_id, user_id \\ nil) do
    RepoRLS.with_user(user_id, fn ->
      # Only update if status is 'sent' (don't overwrite 'read')
      from(m in Message, where: m.id == ^message_id and m.status == "sent")
      |> Repo.update_all(set: [status: "delivered"])
    end)
  end

  def can_delete_message_for_everyone?(chat_id, user_id, from_id) do
    from_id == user_id ||
      Repo.exists?(
        from p in Participant,
          where:
            p.chat_id == ^chat_id and
              p.user_id == ^user_id and
              p.role in ["owner", "admin"]
      )
  end

  def delete_message(chat_id, message_id, user_id, for_everyone \\ true) do
    RepoRLS.with_user(user_id, fn ->
      if not is_participant?(chat_id, user_id) do
        {:error, :forbidden}
      else
        case Ecto.UUID.cast(message_id) do
          :error ->
            {:error, :invalid_id}

          {:ok, uuid} ->
            case Repo.one(from m in Message, where: m.id == ^uuid and m.chat_id == ^chat_id) do
              nil ->
                {:error, :not_found}

              %Message{} = message ->
                if for_everyone && not can_delete_message_for_everyone?(chat_id, user_id, message.from_id) do
                  {:error, :forbidden}
                else
                  Repo.transaction(fn ->
                    from(r in MessageRead, where: r.message_id == ^uuid) |> Repo.delete_all()
                    from(pm in PinnedMessage, where: pm.message_id == ^uuid) |> Repo.delete_all()
                    Repo.delete!(message)
                  end)

                  {:ok, message}
                end
            end
        end
      end
    end)
  end

  def edit_message(chat_id, message_id, user_id, encrypted_content, edited_at \\ nil) do
    RepoRLS.with_user(user_id, fn ->
      if not is_participant?(chat_id, user_id) do
        {:error, :forbidden}
      else
        case Ecto.UUID.cast(message_id) do
          :error ->
            {:error, :invalid_id}

          {:ok, uuid} ->
            case Repo.one(from m in Message, where: m.id == ^uuid and m.chat_id == ^chat_id) do
              nil ->
                {:error, :not_found}

              %Message{} = message ->
                if message.from_id != user_id do
                  {:error, :forbidden}
                else
                  next_timestamp =
                    cond do
                      is_integer(edited_at) and edited_at > 0 -> max(message.timestamp || 0, edited_at)
                      true -> message.timestamp
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
  end

  def list_pinned_messages(chat_id, user_id) do
    RepoRLS.with_user(user_id, fn ->
      Repo.all(
        from pm in PinnedMessage,
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
    end)
  end

  def set_message_pin(chat_id, message_id, user_id, pinned \\ true) do
    RepoRLS.with_user(user_id, fn ->
      if not is_participant?(chat_id, user_id) do
        {:error, :forbidden}
      else
        case Ecto.UUID.cast(message_id) do
          :error ->
            {:error, :invalid_id}

          {:ok, uuid} ->
            if pinned do
              case Repo.one(from m in Message, where: m.id == ^uuid and m.chat_id == ^chat_id) do
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
                where: pm.user_id == ^user_id and pm.chat_id == ^chat_id and pm.message_id == ^uuid
              )
              |> Repo.delete_all()

              {:ok, :unpinned}
            end
        end
      end
    end)
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
            from pm in PinnedMessage,
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
    from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
    |> Repo.update_all(set: [muted: muted])
  end

  def set_pinned(chat_id, user_id, pinned) do
    from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
    |> Repo.update_all(set: [pinned: pinned])
  end

  def set_marked_unread(chat_id, user_id, marked) do
    from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
    |> Repo.update_all(set: [marked_unread: marked])
  end

  def delete_chat(chat_id, user_id) do
    # Instead of deleting the chat, we mark the participant as deleted
    # This way the other user can still see the chat
    case from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
         |> Repo.update_all(set: [deleted: true, messages_cleared_at: NaiveDateTime.utc_now()]) do
      {1, _} -> {:ok, :deleted}
      {0, _} -> {:error, "Chat not found"}
      _ -> {:error, "Failed to delete"}
    end
  end

  def restore_if_deleted(chat_id, user_id) do
    # Check if this user has deleted the chat
    participant = Repo.one(from p in Participant,
                           where: p.chat_id == ^chat_id and p.user_id == ^user_id)

    cond do
      is_nil(participant) ->
        # No participant record - shouldn't happen but treat as not deleted
        :not_deleted
      participant.deleted == true ->
        # Was deleted - restore it
        from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
        |> Repo.update_all(set: [deleted: false])
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

    Repo.transaction(fn ->
      room = Repo.insert!(%Room{
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
  end

  def add_member(chat_id, user_id, role \\ "member") do
    %Participant{}
    |> Participant.changeset(%{chat_id: chat_id, user_id: user_id, role: role})
    |> Repo.insert(on_conflict: :nothing)
  end

  def remove_member(chat_id, user_id) do
    from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
    |> Repo.delete_all()
  end

  # ── Channels ────────────────────────────────────────────────────

  def create_channel(creator_id, name, description \\ nil) do
    id = Ecto.UUID.generate() |> String.slice(0, 12)

    Repo.transaction(fn ->
      room = Repo.insert!(%Room{
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
  end

  def join_channel(channel_id, user_id) do
    # Verify it's a channel
    case Repo.get(Room, channel_id) do
      %Room{type: "channel"} ->
        %Participant{}
        |> Participant.changeset(%{chat_id: channel_id, user_id: user_id, role: "subscriber"})
        |> Repo.insert(on_conflict: :nothing)

      _ ->
        {:error, "Not a channel"}
    end
  end

  def leave_channel(channel_id, user_id) do
    # Don't allow owner to leave
    case Repo.one(from p in Participant,
                   where: p.chat_id == ^channel_id and p.user_id == ^user_id) do
      %Participant{role: "owner"} ->
        {:error, "Owner cannot leave channel"}

      %Participant{} = participant ->
        Repo.delete(participant)

      nil ->
        {:error, "Not a member"}
    end
  end

  def list_channels do
    Repo.all(
      from r in Room,
        where: r.type == "channel",
        order_by: [desc: r.inserted_at],
        preload: [:creator]
    )
    |> Enum.map(fn room ->
      subscriber_count = Repo.aggregate(
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
          from p in Participant,
            where: p.chat_id == ^chat_id and p.user_id == ^user_id
              and p.role in ["owner", "admin"]
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
      from p in Participant,
        where: p.chat_id == ^chat_id and p.user_id == ^user_id,
        select: p.role
    )
  end

  def get_room_type(chat_id) do
    Repo.one(from r in Room, where: r.id == ^chat_id, select: r.type)
  end

  def get_user_channels(user_id) do
    Repo.all(
      from p in Participant,
        join: r in Room, on: r.id == p.chat_id,
        where: p.user_id == ^user_id and r.type == "channel" and p.role == "owner",
        select: %{id: r.id, name: r.name}
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
      from sp in ScheduledPost,
        where: sp.channel_id == ^channel_id and sp.status == "pending",
        order_by: [asc: sp.scheduled_at]
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
    if is_agent_message?(message) do
      plain_text = AgentMessageCrypto.decrypt_from_storage(message.encrypted_content || "")
      base = base_message_map(message)

      Map.merge(base, %{
        encrypted_content: "",
        plaintext: plain_text,
        plain_content: plain_text,
        is_agent_message: true,
        agent_name: "Vibe AI"
      })
    else
      message
    end
  end

  defp to_client_message(other), do: other

  defp is_agent_message?(%Message{from_id: from_id}) do
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
      media_url: message.media_url,
      reply_to_id: message.reply_to_id
    }
  end
end
