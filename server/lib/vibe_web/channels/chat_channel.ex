defmodule VibeWeb.ChatChannel do
  use VibeWeb, :channel
  alias Vibe.Chat
  alias Vibe.Notifications
  alias Vibe.AI.GroupAgent
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
      broadcast_payload = enforce_sender_identity(data, user_id)

      message_attrs = %{
        chat_id: chat_id,
        from_id: user_id,
        id: data["id"],
        encrypted_content: data["encryptedContent"],
        type: data["type"] || "text",
        timestamp: data["timestamp"] || :os.system_time(:millisecond),
        reply_to_id: data["replyToId"],
        media_url: data["mediaUrl"]
      }

      # BROADCAST IMMEDIATELY for instant message delivery
      broadcast!(socket, "message", broadcast_payload)

      # Check for @vibe agent mention and dispatch to group agent
      maybe_dispatch_agent(chat_id, data, user_id)

      # Persist to database asynchronously (don't block message delivery)
      Task.start(fn ->
        case Chat.add_message(message_attrs, acting_user_id: user_id) do
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
                      "body" => push_body,
                      "media_url" => data["mediaUrl"] || data["media_url"]
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
    Vibe.Chat.mark_delivered(msg_id, socket.assigns.user_id)
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

  # ── Agent Dispatch ──

  defp maybe_dispatch_agent(chat_id, data, user_id) do
    Logger.info("[ChatChannel] maybe_dispatch_agent chat_id=#{chat_id} keys=#{inspect(Map.keys(data))} agentMention=#{inspect(data["agentMention"])} agentText=#{inspect(data["agentText"])}")

    agent_mention = data["agentMention"] || false
    agent_text = data["agentText"]
    reply_to_id = data["replyToId"] || data["reply_to_id"]

    # Check if this is a direct @mention
    is_direct_mention = agent_mention && is_binary(agent_text) && agent_text != ""

    # Check if this is a reply to an agent message (follow-up without @mention)
    is_reply_to_agent =
      if !is_direct_mention && is_binary(reply_to_id) && reply_to_id != "" do
        case Chat.get_message(chat_id, reply_to_id, user_id) do
          %{from_id: from_id} ->
            normalized_from = from_id |> to_string() |> String.downcase() |> String.trim()
            normalized_agent = GroupAgent.agent_user_id() |> String.downcase() |> String.trim()
            normalized_from == normalized_agent

          _ ->
            false
        end
      else
        false
      end

    if is_direct_mention || is_reply_to_agent do
      # For reply-to-agent, use the plain text from the message since there's no agentText
      dispatch_text =
        if is_direct_mention do
          agent_text
        else
          # Extract text from the message payload for reply-to-agent
          data["agentText"] || data["pushPreview"] || data["textPreview"] || data["text"] || ""
        end

      if is_binary(dispatch_text) && String.trim(dispatch_text) != "" do
        trigger_type = if is_direct_mention, do: "mention", else: "reply"
        attachment_context = extract_agent_attachment_context(chat_id, data, user_id)

        metadata = %{
          "image_urls" => attachment_context.image_urls,
          "document_urls" => attachment_context.document_urls,
          "reply_to_id" => data["id"],
          "message_id" => data["id"],
          "trigger_type" => trigger_type
        }

        Task.start(fn ->
          Logger.info("[ChatChannel] Dispatching agent (#{trigger_type}) for chat #{chat_id} text=#{String.slice(dispatch_text, 0..100)}")

          # Broadcast typing indicator from agent
          VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "typing", %{
            "userId" => GroupAgent.agent_user_id(),
            "isAgent" => true
          })

          VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-progress", %{
            "userId" => GroupAgent.agent_user_id(),
            "isAgent" => true,
            "label" => "Thinking...",
            "status" => "running"
          })

          try do
            case GroupAgent.handle_mention(chat_id, dispatch_text, user_id, metadata) do
              {:ok, _response} ->
                Logger.info("[ChatChannel] Agent responded in chat #{chat_id}")

              {:error, :no_agent} ->
                Logger.debug("[ChatChannel] No agent configured for chat #{chat_id}")

              {:error, reason} ->
                Logger.error("[ChatChannel] Agent dispatch failed for chat #{chat_id}: #{inspect(reason)}")
            end
          after
            VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-progress", %{
              "userId" => GroupAgent.agent_user_id(),
              "isAgent" => true,
              "status" => "done"
            })

            # Stop typing indicator
            VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "stop-typing", %{
              "userId" => GroupAgent.agent_user_id(),
              "isAgent" => true
            })
          end
        end)
      else
        Logger.info("[ChatChannel] Reply to agent but empty text for chat #{chat_id}")
      end
    else
      Logger.info("[ChatChannel] No agent mention detected for chat #{chat_id}")
    end
  end

  defp extract_agent_attachment_context(chat_id, data, user_id) do
    seeded_images = normalize_urls(data["agentImageUrls"] || data["agent_image_urls"])
    seeded_documents = normalize_urls(data["agentDocumentUrls"] || data["agent_document_urls"])

    from_current =
      classify_attachment(
        data["type"] || data["messageType"] || data["message_type"],
        data["mediaUrl"] || data["media_url"]
      )

    reply_media =
      case data["replyToId"] || data["reply_to_id"] do
        reply_id when is_binary(reply_id) and reply_id != "" ->
          case Chat.get_message(chat_id, reply_id, user_id) do
            nil -> nil
            message -> classify_attachment(message.type, message.media_url)
          end

        _ ->
          nil
      end

    image_urls =
      seeded_images
      |> maybe_add_classified_attachment(from_current, :image)
      |> maybe_add_classified_attachment(reply_media, :image)
      |> Enum.uniq()

    document_urls =
      seeded_documents
      |> maybe_add_classified_attachment(from_current, :document)
      |> maybe_add_classified_attachment(reply_media, :document)
      |> Enum.uniq()

    %{image_urls: image_urls, document_urls: document_urls}
  end

  defp normalize_urls(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_urls(value) when is_binary(value), do: normalize_urls([value])
  defp normalize_urls(_), do: []

  defp maybe_add_classified_attachment(urls, {:image, url}, :image), do: [url | urls]
  defp maybe_add_classified_attachment(urls, {:document, url}, :document), do: [url | urls]
  defp maybe_add_classified_attachment(urls, _attachment, _kind), do: urls

  defp classify_attachment(raw_type, raw_url) do
    type = normalize_type(raw_type)
    url = normalize_url(raw_url)

    cond do
      is_nil(url) ->
        nil

      type in ["image", "gif", "sticker"] ->
        {:image, url}

      type in ["file", "document", "pdf"] ->
        {:document, url}

      image_url?(url) ->
        {:image, url}

      document_url?(url) ->
        {:document, url}

      true ->
        nil
    end
  end

  defp normalize_type(raw_type) do
    raw_type
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_url(raw_url) when is_binary(raw_url) do
    trimmed = String.trim(raw_url)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_url(_), do: nil

  defp image_url?(url) when is_binary(url) do
    lower = String.downcase(url)
    Enum.any?([".png", ".jpg", ".jpeg", ".webp", ".gif", ".heic", ".bmp"], &String.contains?(lower, &1))
  end

  defp document_url?(url) when is_binary(url) do
    lower = String.downcase(url)
    Enum.any?([".pdf", ".doc", ".docx", ".ppt", ".pptx", ".xls", ".xlsx", ".txt", ".rtf", ".md"], &String.contains?(lower, &1))
  end

  defp enforce_sender_identity(payload, user_id) when is_map(payload) do
    payload
    |> Map.put("fromId", user_id)
    |> Map.put("from_id", user_id)
  end

  defp deobfuscate(%{"d" => encoded}) do
    encoded
    |> Base.decode64!(ignore: :whitespace)
    |> Jason.decode!()
  end
  defp deobfuscate(map), do: map # Fallback if not obfuscated
end
