defmodule VibeWeb.AgentChannel do
  @moduledoc """
  Phoenix Channel for real-time AI Agent communication.
  Supports streaming responses with tool progress updates.
  Now with database-backed conversation history for business use.
  """

  use Phoenix.Channel
  require Logger

  alias Vibe.AI.Agent
  alias Vibe.AI.AgentBuilder
  alias Vibe.AgentConversation

  @doc """
  Join the agent channel for a user.
  """
  def join("agent:" <> user_id, params, socket) do
    # Verify user matches socket assigns
    if socket.assigns[:user_id] == user_id do
      conversation_id = params["conversation_id"]

      socket = socket
        |> assign(:conversation_history, [])
        |> assign(:active_conversation_id, conversation_id)

      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @doc """
  Handle incoming messages to the AI agent.
  """
  def handle_in("message", %{"text" => text} = params, socket) do
    images = params["images"] || []
    conversation_id = params["conversation_id"] || socket.assigns[:active_conversation_id]
    user_id = socket.assigns[:user_id]
    truncate_id = params["truncate_at_id"]

    # Handle truncation if requested (for regeneration)
    if truncate_id && conversation_id do
      AgentConversation.truncate_history(conversation_id, user_id, truncate_id)
    end

    # Get or create conversation
    {conv_id, history} = get_or_create_conversation(user_id, conversation_id, text)


    # Store conversation ID in socket
    socket = assign(socket, :active_conversation_id, conv_id)

    # Acknowledge receipt with conversation ID
    push(socket, "ack", %{status: "processing", conversation_id: conv_id})

    # Add user message to database
    AgentConversation.add_message(conv_id, %{
      "role" => "user",
      "content" => text,
      "images" => images
    })

    # Start async task for AI response
    channel_pid = self()

    Task.start(fn ->
      # Create placeholder assistant message
      {:ok, _conv} = AgentConversation.add_message(conv_id, %{
        "role" => "assistant",
        "content" => "",
        "isStreaming" => true
      })

      callback = streaming_callback(channel_pid, conv_id)

      case Agent.stream_response(text, callback, history: history, images: images, user_id: user_id) do
        {:ok, full_response, _runtime_state} ->
          # Update the assistant message in database
          send(channel_pid, {:finalize_message, conv_id, full_response})
          send(channel_pid, {:push, "done", %{success: true, conversation_id: conv_id}})

        {:ok, full_response} ->
          # Update the assistant message in database
          send(channel_pid, {:finalize_message, conv_id, full_response})
          send(channel_pid, {:push, "done", %{success: true, conversation_id: conv_id}})

        {:error, reason} ->
          Logger.error("Agent error: #{inspect(reason)}")
          send(channel_pid, {:push, "error", %{message: to_string(reason)}})
      end
    end)

    {:noreply, socket}
  end

  def handle_in("builder_ui_response", %{"ui_response" => ui_response} = params, socket)
      when is_map(ui_response) do
    user_id = socket.assigns[:user_id]
    conversation_id = params["conversation_id"] || socket.assigns[:active_conversation_id]
    summary = normalize_summary(params["summary"])
    active_agent_id = normalize_optional_string(params["active_agent_id"])

    with {:ok, conv_id} <- ensure_existing_conversation(user_id, conversation_id) do
      socket = assign(socket, :active_conversation_id, conv_id)
      push(socket, "ack", %{status: "processing", conversation_id: conv_id})

      if is_binary(summary) do
        AgentConversation.add_message(conv_id, %{
          "role" => "user",
          "content" => summary
        })
      end

      channel_pid = self()

      Task.start(fn ->
        {:ok, _conv} =
          AgentConversation.add_message(conv_id, %{
            "role" => "assistant",
            "content" => "",
            "isStreaming" => true
          })

        callback = streaming_callback(channel_pid, conv_id)

        case AgentBuilder.stream_message(
               user_id,
               summary,
               callback,
               active_agent_id: active_agent_id,
               ui_response: ui_response
             ) do
          {:ok, result} ->
            send(channel_pid, {:finalize_message, conv_id, result[:reply] || result["reply"]})
            send(channel_pid, {:push, "done", %{success: true, conversation_id: conv_id}})

          {:error, reason} ->
            Logger.error("Builder UI response error: #{inspect(reason)}")
            send(channel_pid, {:push, "error", %{message: to_string(reason)}})
        end
      end)

      {:noreply, socket}
    else
      _ ->
        {:reply, {:error, %{reason: "conversation_required"}}, socket}
    end
  end

  def handle_in("builder_create_draft", params, socket) do
    answers =
      case params["agentEnabled"] do
        nil -> %{}
        value -> %{"agentEnabled" => value}
      end

    ui_response = %{
      "requestId" => "setup:create_draft",
      "answers" => answers
    }

    handle_in(
      "builder_ui_response",
      %{
        "conversation_id" => params["conversation_id"],
        "summary" => "Create draft",
        "active_agent_id" => params["active_agent_id"],
        "ui_response" => ui_response
      },
      socket
    )
  end

  # List conversations for a user
  def handle_in("list_conversations", _params, socket) do
    user_id = socket.assigns[:user_id]
    conversations = AgentConversation.list_for_user(user_id)

    {:reply, {:ok, %{conversations: conversations}}, socket}
  end

  # Get a specific conversation
  def handle_in("get_conversation", %{"id" => id}, socket) do
    user_id = socket.assigns[:user_id]

    case AgentConversation.get_full(id, user_id) do
      nil -> {:reply, {:error, %{reason: "not_found"}}, socket}
      conv -> {:reply, {:ok, conv}, socket}
    end
  end

  # Create a new conversation
  def handle_in("create_conversation", %{"title" => title}, socket) do
    user_id = socket.assigns[:user_id]

    case AgentConversation.create(user_id, title) do
      {:ok, conv} ->
        socket = assign(socket, :active_conversation_id, conv.id)
        {:reply, {:ok, %{id: conv.id, title: conv.title}}, socket}
      {:error, _} ->
        {:reply, {:error, %{reason: "failed_to_create"}}, socket}
    end
  end

  # Delete a conversation
  def handle_in("delete_conversation", %{"id" => id}, socket) do
    user_id = socket.assigns[:user_id]

    case AgentConversation.delete(id, user_id) do
      {:ok, _} -> {:reply, {:ok, %{deleted: true}}, socket}
      {:error, _} -> {:reply, {:error, %{reason: "not_found"}}, socket}
    end
  end

  # Set active conversation
  def handle_in("set_conversation", %{"id" => id}, socket) do
    socket = assign(socket, :active_conversation_id, id)
    {:reply, {:ok, %{active: id}}, socket}
  end

  # Clear conversation history
  def handle_in("clear_history", _params, socket) do
    conv_id = socket.assigns[:active_conversation_id]
    user_id = socket.assigns[:user_id]

    if conv_id do
      AgentConversation.clear_messages(conv_id, user_id)
    end

    {:reply, {:ok, %{cleared: true}}, assign(socket, :conversation_history, [])}
  end

  # Handle push messages from the async task
  def handle_info({:push, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info({:append_content, chunk}, socket) do
    current = socket.assigns[:streaming_content] || ""
    {:noreply, assign(socket, :streaming_content, current <> chunk)}
  end

  def handle_info({:add_tool_result, result}, socket) do
    current = socket.assigns[:tool_results] || []
    {:noreply, assign(socket, :tool_results, current ++ [result])}
  end

  def handle_info({:finalize_message, conv_id, full_response}, socket) do
    tool_results = socket.assigns[:tool_results] || []

    # Update the last message in the database
    AgentConversation.update_last_message(conv_id, %{
      "content" => full_response,
      "isStreaming" => false,
      "toolResults" => tool_results
    })

    # Reset streaming state
    socket = socket
      |> assign(:streaming_content, "")
      |> assign(:tool_results, [])

    {:noreply, socket}
  end

  def handle_info({:update_history, history}, socket) do
    # Keep only last 20 messages to manage token usage
    trimmed = Enum.take(history, -20)
    {:noreply, assign(socket, :conversation_history, trimmed)}
  end

  # Private helpers

  defp get_or_create_conversation(user_id, nil, first_message) do
    # Create new conversation with placeholder title
    {:ok, conv} = AgentConversation.create(user_id, "New Chat")

    # Generate title asynchronously using AI
    Task.start(fn -> generate_title_async(conv.id, first_message) end)

    {conv.id, []}
  end

  defp get_or_create_conversation(user_id, conv_id, _first_message) do
    case AgentConversation.get_for_user(conv_id, user_id) do
      nil ->
        # Conversation not found, create new
        {:ok, conv} = AgentConversation.create(user_id, "New Chat")
        {conv.id, []}

      conv ->
        # Convert stored messages to history format for Claude
        history = Enum.map(conv.messages, fn msg ->
          %{role: msg["role"], content: msg["content"] || ""}
        end)
        |> Enum.filter(fn msg -> msg.content != "" end)
        |> Enum.take(-20)  # Keep last 20 for token limit

        {conv.id, history}
    end
  end

  defp streaming_callback(channel_pid, conversation_id) do
    fn
      %{type: :text, content: chunk} ->
        send(channel_pid, {:push, "chunk", %{text: chunk, conversation_id: conversation_id}})
        send(channel_pid, {:append_content, chunk})

      %{type: :progress, label: label} = payload ->
        send(channel_pid, {:push, "progress", %{
          label: label,
          tool: payload[:tool],
          status: payload[:status] || "running",
          conversation_id: conversation_id
        }})

      %{type: :subagent} = payload ->
        send(
          channel_pid,
          {:push, "subagent", Map.put(Map.delete(payload, :type), :conversation_id, conversation_id)}
        )

      %{type: :tool_result, tool: tool, result: result} = payload ->
        send(channel_pid, {:push, "tool_result", %{
          tool: tool,
          result: result,
          status: payload[:status] || "complete",
          duration_ms: payload[:duration_ms],
          conversation_id: conversation_id
        }})
        send(channel_pid, {:add_tool_result, %{tool: tool, result: result}})

      %{type: :agent_cards, cards: cards} = payload ->
        send(channel_pid, {:push, "agent_cards", %{
          cards: cards,
          group_id: payload[:group_id] || payload["group_id"],
          conversation_id: conversation_id
        }})

      %{type: :state} = payload ->
        send(
          channel_pid,
          {:push, "builder_state", Map.put(Map.delete(payload, :type), :conversation_id, conversation_id)}
        )

      %{type: :ui_request} = payload ->
        send(
          channel_pid,
          {:push, "ui_request", Map.put(Map.delete(payload, :type), :conversation_id, conversation_id)}
        )

      %{type: :review_ready} = payload ->
        send(
          channel_pid,
          {:push, "review_ready", Map.put(Map.delete(payload, :type), :conversation_id, conversation_id)}
        )
    end
  end

  defp ensure_existing_conversation(user_id, nil) do
    {:ok, conv} = AgentConversation.create(user_id, "New Chat")
    {:ok, conv.id}
  end

  defp ensure_existing_conversation(user_id, conv_id) do
    case AgentConversation.get_for_user(conv_id, user_id) do
      nil ->
        {:error, :not_found}

      _conv ->
        {:ok, conv_id}
    end
  end

  defp normalize_summary(nil), do: nil

  defp normalize_summary(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: String.slice(trimmed, 0, 500)
  end

  defp normalize_summary(value), do: to_string(value) |> normalize_summary()

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(value), do: value |> to_string() |> normalize_optional_string()

  # Generate a short, descriptive title using AI
  defp generate_title_async(conv_id, message) do
    prompt = """
    Generate a very short title (3-5 words max) for a conversation that starts with this message:
    "#{String.slice(message, 0..200)}"

    Rules:
    - Maximum 5 words
    - No quotes or punctuation at the end
    - Be specific and descriptive
    - Don't start with "Chat about" or similar

    Just respond with the title, nothing else.
    """

    case Vibe.AI.Agent.quick_completion(prompt) do
      {:ok, title} ->
        clean_title = title
          |> String.trim()
          |> String.replace(~r/^["']|["']$/, "")
          |> String.slice(0..50)

        AgentConversation.update_title(conv_id, clean_title)
        Logger.info("Generated title for #{conv_id}: #{clean_title}")

        # Broadcast title update to client
        VibeWeb.Endpoint.broadcast("agent:*", "title_updated", %{
          conversation_id: conv_id,
          title: clean_title
        })

      {:error, reason} ->
        Logger.warn("Failed to generate title: #{inspect(reason)}")
        # Fall back to first 30 chars
        fallback = String.slice(message, 0..30)
        AgentConversation.update_title(conv_id, fallback)
    end
  end
end
