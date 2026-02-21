defmodule VibeWeb.ChatChannel do
  use VibeWeb, :channel
  alias Vibe.Chat
  alias Vibe.Notifications
  require Logger

  @impl true
  def join("chat:" <> chat_id, _payload, socket) do
    user_id = socket.assigns.user_id
    # Verify access and cache room type + role in socket assigns
    # so we skip DB queries on every message send.
    case Chat.get_user_role(chat_id, user_id) do
      nil ->
        {:error, %{reason: "unauthorized"}}
      role ->
        room_type = Chat.get_room_type(chat_id) || "dm"
        socket = assign(socket, :room_type, room_type)
        socket = assign(socket, :user_role, role)
        {:ok, socket}
    end
  end

  @impl true
  def handle_in("message", payload, socket) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id

    # Check send permission using cached socket assigns (no DB hit)
    can_send = case socket.assigns.room_type do
      "channel" -> socket.assigns.user_role in ["owner", "admin"]
      _ -> true  # Already verified as participant on join
    end

    if not can_send do
      {:reply, {:error, %{reason: "not_allowed", message: "You cannot send messages here"}}, socket}
    else
      data = deobfuscate(payload)

      message_attrs = %{
        chat_id: chat_id,
        from_id: data["fromId"] || user_id,
        id: data["id"],
        encrypted_content: data["encryptedContent"],
        type: data["type"] || "text",
        timestamp: data["timestamp"] || :os.system_time(:millisecond),
        reply_to_id: data["replyToId"],
        media_url: data["mediaUrl"]
      }

      # BROADCAST IMMEDIATELY for instant message delivery
      broadcast!(socket, "message", payload)

      # Persist to database asynchronously (don't block message delivery)
      Task.start(fn ->
        case Chat.add_message(message_attrs) do
          {:ok, _msg} ->
            # Batch-fetch all participants with settings in ONE query (no N+1)
            participants = Chat.get_all_participant_settings(chat_id)
            Logger.info(
              "[ChatChannel] message persisted chat_id=#{chat_id} sender=#{user_id} participants=#{length(participants)} message_id=#{data["id"]}"
            )

            Enum.each(participants, fn p ->
              if p.user_id != user_id do
                if p.deleted, do: Chat.restore_if_deleted(chat_id, p.user_id)

                VibeWeb.Endpoint.broadcast!("user:#{p.user_id}", "new_message", %{
                  chat_id: chat_id,
                  from_id: user_id,
                  message_id: data["id"],
                  timestamp: data["timestamp"],
                  muted: p.muted || false
                })

                if p.muted do
                  Logger.info(
                    "[ChatChannel] push skipped (muted chat) recipient=#{p.user_id} chat_id=#{chat_id} message_id=#{data["id"]}"
                  )
                else
                  push_body =
                    case data["pushPreview"] || data["push_preview"] || data["textPreview"] || data["text_preview"] do
                      value when is_binary(value) and value != "" -> value
                      _ -> nil
                    end

                  _ =
                    Notifications.send_message_push(p.user_id, %{
                      "chat_id" => chat_id,
                      "message_id" => data["id"],
                      "from_id" => user_id,
                      "type" => data["type"],
                      "body" => push_body
                    })
                end
              end
            end)

          {:error, changeset} ->
            # Log persistence failure but don't crash
            Logger.error("Message persistence failed: #{inspect(changeset)}")
        end
      end)

      # Reply immediately - don't wait for DB
      {:reply, :ok, socket}
    end
  end

  @impl true
  def handle_in("typing", payload, socket) do
    broadcast_from!(socket, "typing", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("recording", payload, socket) do
    broadcast_from!(socket, "recording", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("stop-recording", payload, socket) do
    broadcast_from!(socket, "stop-recording", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("stop-typing", payload, socket) do
    broadcast_from!(socket, "stop-typing", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("read-receipt", %{"messageId" => msg_id} = payload, socket) do
    Vibe.Chat.mark_read(msg_id, socket.assigns.user_id)
    broadcast_from!(socket, "message-read", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("delivery-receipt", %{"messageId" => msg_id} = payload, socket) do
    Vibe.Chat.mark_delivered(msg_id)
    broadcast_from!(socket, "message-delivered", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("delete-message", %{"messageId" => msg_id} = payload, socket) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id
    for_everyone =
      case Map.get(payload, "forEveryone", true) do
        v when v in [true, "true", "1", 1] -> true
        _ -> false
      end

    case Vibe.Chat.delete_message(chat_id, msg_id, user_id, for_everyone) do
      {:ok, _message} ->
        broadcast!(socket, "message-deleted", %{
          messageId: msg_id,
          deletedBy: user_id,
          forEveryone: for_everyone
        })

        {:reply, :ok, socket}

      {:error, :invalid_id} ->
        {:reply, {:error, %{reason: "invalid_id"}}, socket}

      {:error, :forbidden} ->
        {:reply, {:error, %{reason: "forbidden"}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "not_found"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("edit-message", %{"messageId" => msg_id, "encryptedContent" => encrypted_content} = payload, socket) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id
    edited_at = Map.get(payload, "editedAt")

    case Vibe.Chat.edit_message(chat_id, msg_id, user_id, encrypted_content, edited_at) do
      {:ok, _message} ->
        broadcast!(socket, "message-edited", %{
          messageId: msg_id,
          encryptedContent: encrypted_content,
          editedAt: edited_at || :os.system_time(:millisecond),
          editedBy: user_id
        })

        {:reply, :ok, socket}

      {:error, :invalid_id} ->
        {:reply, {:error, %{reason: "invalid_id"}}, socket}

      {:error, :forbidden} ->
        {:reply, {:error, %{reason: "forbidden"}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "not_found"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  defp deobfuscate(%{"d" => encoded}) do
    encoded
    |> Base.decode64!(ignore: :whitespace)
    |> Jason.decode!()
  end
  defp deobfuscate(map), do: map # Fallback if not obfuscated
end
