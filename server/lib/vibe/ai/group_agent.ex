defmodule Vibe.AI.GroupAgent do
  @moduledoc """
  AI Agent for group/channel chats.
  Handles @vibe mentions, generates responses with per-group custom prompts,
  and manages conversation memory with auto-compaction.
  """

  require Logger

  alias Vibe.Chat.{GroupAgent, GroupAgentMemory}

  @claude_api "https://api.anthropic.com/v1/messages"
  @claude_model "claude-haiku-4-5-20251001"

  # Well-known UUID for the Vibe AI agent virtual user
  @agent_user_id "00000000-0000-0000-0000-000000000001"

  # Memory thresholds
  @compaction_threshold 50
  @keep_recent_count 10
  @context_message_limit 30

  # Tools available to group agents
  @tools [
    %{
      name: "search_google",
      description: "Search the web using Google. Returns relevant web results.",
      input_schema: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "Search query"}
        },
        required: ["query"]
      }
    },
    %{
      name: "analyze_image",
      description: "Analyze an image URL. Can describe contents, read text (OCR), identify objects.",
      input_schema: %{
        type: "object",
        properties: %{
          image_url: %{type: "string", description: "URL of the image to analyze"},
          task: %{type: "string", description: "What to do: describe, ocr, identify, or custom question"}
        },
        required: ["image_url"]
      }
    },
    %{
      name: "analyze_document",
      description: "Analyze a document (PDF, text). Extract information, summarize, or answer questions.",
      input_schema: %{
        type: "object",
        properties: %{
          document_url: %{type: "string", description: "URL of the document"},
          task: %{type: "string", description: "What to do: summarize, extract_key_points, answer_question"},
          question: %{type: "string", description: "Optional specific question about the document"}
        },
        required: ["document_url", "task"]
      }
    }
  ]

  @doc """
  Returns the well-known agent user ID constant.
  """
  def agent_user_id, do: @agent_user_id

  @doc """
  Handle an @vibe mention in a group chat.
  Loads agent config, builds context with memory, calls Claude, and broadcasts the response.
  """
  def handle_mention(chat_id, user_message, user_id, metadata \\ %{}) do
    case GroupAgent.get_enabled_by_chat(chat_id) do
      nil ->
        Logger.info("[GroupAgent] No enabled agent for chat #{chat_id}")
        {:error, :no_agent}

      agent_config ->
        process_mention(chat_id, agent_config, user_message, user_id, metadata)
    end
  end

  defp process_mention(chat_id, agent_config, user_message, user_id, metadata) do
    # 1. Load memory
    {:ok, memory} = GroupAgentMemory.get_or_create(chat_id)

    # 2. Build system prompt with memory context
    system_prompt = build_system_prompt(agent_config, memory)

    # 3. Build message history from memory + current message
    messages = build_messages(memory, user_message, metadata)

    # 4. Call Claude
    case call_claude(messages, system_prompt, user_id) do
      {:ok, response} ->
        # 5. Store in memory
        GroupAgentMemory.append_message(chat_id, %{
          "role" => "user",
          "content" => user_message,
          "user_id" => user_id
        })

        GroupAgentMemory.append_message(chat_id, %{
          "role" => "assistant",
          "content" => response
        })

        # 6. Check if compaction needed
        maybe_compact(chat_id)

        # 7. Broadcast agent response as a chat message
        broadcast_agent_message(chat_id, agent_config, response, metadata)

        {:ok, response}

      {:error, reason} ->
        Logger.error("[GroupAgent] Claude error for chat #{chat_id}: #{inspect(reason)}")
        # Broadcast an error message so users know something went wrong
        broadcast_agent_message(chat_id, agent_config, "Sorry, I encountered an error processing your request. Please try again.", metadata)
        {:error, reason}
    end
  end

  defp build_system_prompt(agent_config, memory) do
    base_prompt = """
    #{agent_config.system_prompt}

    IMPORTANT RULES:
    - You are #{agent_config.name}, an AI assistant in this group chat.
    - Keep responses concise and relevant — this is mobile chat.
    - When using tools, call them IMMEDIATELY without intro text.
    - You can reference previous conversations from your memory.
    - Address users naturally, referring to the group context.
    """

    case memory.summary do
      nil -> base_prompt
      "" -> base_prompt
      summary ->
        base_prompt <> "\n\nConversation Memory (summary of earlier interactions):\n#{summary}\n"
    end
  end

  defp build_messages(memory, current_message, metadata) do
    # Take last N messages from memory as context
    recent_messages =
      memory.messages
      |> Enum.take(-@context_message_limit)
      |> Enum.map(fn msg ->
        %{
          role: msg["role"] || "user",
          content: msg["content"] || ""
        }
      end)
      |> Enum.filter(fn msg -> msg.content != "" end)

    # Build current message with optional images
    image_urls = Map.get(metadata, "image_urls", [])
    current_content = if Enum.empty?(image_urls) do
      current_message
    else
      image_blocks = Enum.map(image_urls, fn url ->
        %{type: "image", source: %{type: "url", url: url}}
      end)
      image_blocks ++ [%{type: "text", text: current_message}]
    end

    recent_messages ++ [%{role: "user", content: current_content}]
  end

  defp call_claude(messages, system_prompt, user_id) do
    api_key = System.get_env("ANTHROPIC_API_KEY") || System.get_env("CLAUDE_API_KEY")

    unless api_key do
      {:error, "ANTHROPIC_API_KEY not configured"}
    else
      call_claude_with_tools(messages, system_prompt, api_key, 0, user_id)
    end
  end

  defp call_claude_with_tools(messages, system_prompt, api_key, depth, user_id) do
    if depth > 3 do
      {:error, "Max tool depth reached"}
    else
      body = Jason.encode!(%{
        model: @claude_model,
        max_tokens: 4096,
        system: system_prompt,
        tools: @tools,
        messages: messages
      })

      headers = [
        {"Content-Type", "application/json"},
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"}
      ]

      request = Finch.build(:post, @claude_api, headers, body)

      case Finch.request(request, Vibe.Finch, receive_timeout: 30_000) do
        {:ok, %{status: 200, body: resp_body}} ->
          case Jason.decode(resp_body) do
            {:ok, %{"content" => content, "stop_reason" => "tool_use"}} ->
              # Handle tool calls
              handle_tool_response(content, messages, system_prompt, api_key, depth, user_id)

            {:ok, %{"content" => content}} ->
              # Extract text from response
              text = extract_text(content)
              {:ok, text}

            _ ->
              {:error, "Failed to parse Claude response"}
          end

        {:ok, %{status: status, body: body}} ->
          Logger.error("[GroupAgent] Claude API error: #{status} - #{body}")
          {:error, "API error: #{status}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp handle_tool_response(content, messages, system_prompt, api_key, depth, user_id) do
    # Extract tool calls from content
    tool_calls = Enum.filter(content, fn
      %{"type" => "tool_use"} -> true
      _ -> false
    end)

    # Execute tools
    tool_results = Enum.map(tool_calls, fn tool ->
      result = execute_tool(tool["name"], tool["input"], user_id)
      %{
        "type" => "tool_result",
        "tool_use_id" => tool["id"],
        "content" => Jason.encode!(result)
      }
    end)

    # Build content blocks for assistant message (text + tool_use blocks)
    assistant_content = Enum.map(content, fn
      %{"type" => "text", "text" => text} ->
        %{type: "text", text: text}
      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
        %{type: "tool_use", id: id, name: name, input: input}
      other -> other
    end)

    new_messages = messages ++ [
      %{role: "assistant", content: assistant_content},
      %{role: "user", content: tool_results}
    ]

    call_claude_with_tools(new_messages, system_prompt, api_key, depth + 1, user_id)
  end

  defp execute_tool(name, input, _user_id) do
    start_time = System.monotonic_time(:millisecond)

    result = case name do
      "search_google" -> Vibe.AI.Tools.Search.google(input)
      "analyze_image" -> Vibe.AI.Tools.Vision.analyze(input)
      "analyze_document" -> Vibe.AI.Tools.Document.analyze(input)
      _ -> %{error: "Unknown tool: #{name}"}
    end

    duration_ms = System.monotonic_time(:millisecond) - start_time
    Logger.info("[GroupAgent] Tool #{name} completed in #{duration_ms}ms")

    result
  end

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(fn
      %{"type" => "text"} -> true
      _ -> false
    end)
    |> Enum.map(fn %{"text" => text} -> text end)
    |> Enum.join("")
  end
  defp extract_text(content) when is_binary(content), do: content
  defp extract_text(_), do: ""

  defp broadcast_agent_message(chat_id, agent_config, text, metadata) do
    message_id = Ecto.UUID.generate()
    timestamp = :os.system_time(:millisecond)
    reply_to_id = Map.get(metadata, "reply_to_id")

    payload = %{
      "id" => message_id,
      "fromId" => @agent_user_id,
      "chatId" => chat_id,
      "encryptedContent" => "",
      "plainContent" => text,
      "type" => "text",
      "timestamp" => timestamp,
      "status" => "sent",
      "isAgentMessage" => true,
      "agentName" => agent_config.name,
      "replyToId" => reply_to_id
    }

    # Broadcast to the chat channel
    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "message", payload)

    # Persist the agent message to the database
    Task.start(fn ->
      message_attrs = %{
        id: message_id,
        chat_id: chat_id,
        from_id: @agent_user_id,
        encrypted_content: text,
        type: "text",
        timestamp: timestamp,
        reply_to_id: reply_to_id
      }

      case Vibe.Chat.add_message(message_attrs) do
        {:ok, _msg} ->
          Logger.info("[GroupAgent] Agent message persisted chat_id=#{chat_id} message_id=#{message_id}")

          # Notify all participants about the new message
          participants = Vibe.Chat.get_all_participant_settings(chat_id)
          Enum.each(participants, fn p ->
            VibeWeb.Endpoint.broadcast!("user:#{p.user_id}", "new_message", %{
              chat_id: chat_id,
              from_id: @agent_user_id,
              message_id: message_id,
              timestamp: timestamp,
              muted: p.muted || false
            })
          end)

        {:error, reason} ->
          Logger.error("[GroupAgent] Failed to persist agent message: #{inspect(reason)}")
      end
    end)
  end

  # ── Memory Compaction ──

  defp maybe_compact(chat_id) do
    Task.start(fn ->
      case GroupAgentMemory.get_or_create(chat_id) do
        {:ok, memory} when length(memory.messages) > @compaction_threshold ->
          compact_memory(memory)
        _ ->
          :ok
      end
    end)
  end

  defp compact_memory(memory) do
    messages = memory.messages
    to_compact = Enum.take(messages, length(messages) - @keep_recent_count)
    to_keep = Enum.take(messages, -@keep_recent_count)

    # Format messages for summarization
    conversation_text =
      to_compact
      |> Enum.map(fn msg ->
        role = if msg["role"] == "assistant", do: "Agent", else: "User"
        "#{role}: #{msg["content"]}"
      end)
      |> Enum.join("\n")

    existing_summary = memory.summary || ""
    prompt = """
    Summarize this group chat conversation concisely, preserving key facts, decisions, data, and context that would be needed to continue the conversation. Include specific numbers, names, and commitments.

    #{if existing_summary != "", do: "Previous summary:\n#{existing_summary}\n\nNew messages to incorporate:", else: "Conversation:"}

    #{conversation_text}

    Provide a concise summary (max 500 words):
    """

    case Vibe.AI.Agent.quick_completion(prompt) do
      {:ok, summary} ->
        GroupAgentMemory.update_after_compaction(memory, String.trim(summary), to_keep)
        Logger.info("[GroupAgent] Memory compacted for chat #{memory.chat_id}: #{length(to_compact)} messages summarized")

      {:error, reason} ->
        Logger.error("[GroupAgent] Memory compaction failed for chat #{memory.chat_id}: #{inspect(reason)}")
    end
  end
end
