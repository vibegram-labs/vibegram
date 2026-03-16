defmodule Vibe.AI.Agent do
  @moduledoc """
  AI Agent with tool-use capabilities.
  Tools: Music Search, Google Search, Image/Document Analysis
  """

  require Logger

  alias Vibe.AI.GroupAgent

  @claude_api "https://api.anthropic.com/v1/messages"
  @claude_model "claude-haiku-4-5-20251001"

  # Tool definitions for Claude
  @tools [
    %{
      name: "search_music",
      description: "Search for music tracks, albums, or artists. Returns streaming links from YouTube Music, Spotify, etc.",
      input_schema: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "Song name, artist, or album to search for"},
          type: %{type: "string", enum: ["track", "album", "artist"], description: "Type of search"}
        },
        required: ["query"]
      }
    },
    %{
      name: "search_google",
      description: "Search the web using Google. Returns relevant web results with titles, snippets, and URLs.",
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
      description: "Analyze an image URL. Can describe contents, read text (OCR), identify objects, etc.",
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
      description: "Analyze a document (PDF, text). Extract information, summarize, or answer questions about it.",
      input_schema: %{
        type: "object",
        properties: %{
          document_url: %{type: "string", description: "URL of the document"},
          task: %{type: "string", description: "What to do: summarize, extract_key_points, answer_question"},
          question: %{type: "string", description: "Optional specific question about the document"}
        },
        required: ["document_url", "task"]
      }
    },
    %{
      name: "post_to_channel",
      description: "Post a message to the user's channel. Supports text, images, and media. The message will be broadcast to all channel subscribers.",
      input_schema: %{
        type: "object",
        properties: %{
          channel_id: %{type: "string", description: "The channel ID to post to"},
          content: %{type: "string", description: "The message content to post"},
          type: %{type: "string", enum: ["text", "image", "media"], description: "Type of content"},
          media_url: %{type: "string", description: "URL of the media (for image/media types)"}
        },
        required: ["channel_id", "content"]
      }
    },
    %{
      name: "get_channel_analytics",
      description: "Get analytics for a channel the user owns: subscriber count, message count, recent joins.",
      input_schema: %{
        type: "object",
        properties: %{
          channel_id: %{type: "string", description: "The channel ID to get analytics for"}
        },
        required: ["channel_id"]
      }
    },
    %{
      name: "schedule_channel_post",
      description: "Schedule a post to be published to a channel at a specific future time.",
      input_schema: %{
        type: "object",
        properties: %{
          channel_id: %{type: "string", description: "The channel ID to post to"},
          content: %{type: "string", description: "The message content to post"},
          type: %{type: "string", enum: ["text", "image", "media"], description: "Type of content"},
          media_url: %{type: "string", description: "URL of the media (for image/media types)"},
          scheduled_at: %{type: "string", description: "ISO8601 datetime when to publish (e.g. 2026-02-06T18:00:00Z)"}
        },
        required: ["channel_id", "content", "scheduled_at"]
      }
    }
  ]

  @system_prompt """
  You are Vibe AI, a helpful assistant in a messaging app.

  CRITICAL TOOL USAGE RULES:
  1. WHEN USING ANY TOOL: Call the tool IMMEDIATELY without ANY intro text.
     - WRONG: "Sure, let me search for that..." then tool call
     - CORRECT: Just call the tool directly, no text before it

  2. search_music: Use when user asks for songs, music, artists, or albums.
     - If the user provides lyrics (e.g., "music that says 'some part of music'"), search for the lyrics or the inferred song title.
     - If the user describes a vibe or sound, keyword search for it.
     - Examples:
       * User: "play the song that goes 'is this the real life'" -> Tool: search_music(query: "Bohemian Rhapsody Queen")
       * User: "I want that song about driving fast cars" -> Tool: search_music(query: "song about driving fast cars")
       * User: "play some energetic workout music" -> Tool: search_music(query: "energetic workout music")
     - Correct typos intelligently (e.g., "tylor swift" → "Taylor Swift")
     - ALWAYS provide the "query" parameter.
     - After results: Write a brief, natural response acknowledging the music.
       Examples: "Here's that track for you 🎵", "Got it!", "Enjoy the music!"
     - If multiple results returned, you can mention: "I also found some alternatives if you want something different."
     - NEVER list track names, URLs, or links - the UI shows them automatically.
     - NEVER write YouTube URLs or any links in your response.

  3. search_google: Use when user needs current info, facts, or web lookup.
     - ALWAYS provide the "query" parameter.

  4. analyze_image: Use when user shares an image URL.
     - ALWAYS provide "image_url" parameter.

  5. analyze_document: Use when user shares a document URL.
     - ALWAYS provide "document_url" and "task" parameters.

  ON ERRORS:
  - If a tool returns an error, inform the user briefly. Do NOT retry.
  - Example: "Sorry, couldn't find that."

  6. post_to_channel: Use when user asks to post/publish something to their channel.
     - ALWAYS provide "channel_id" and "content" parameters.
     - If user doesn't specify channel_id, ask which channel they want to post to.
     - After posting: Confirm briefly, e.g., "Posted to your channel!"

  7. get_channel_analytics: Use when user asks about channel stats, subscribers, activity.
     - ALWAYS provide "channel_id" parameter.
     - Present analytics in a brief, readable format.

  8. schedule_channel_post: Use when user asks to schedule a post for later.
     - ALWAYS provide "channel_id", "content", and "scheduled_at" (ISO8601 format).
     - Convert natural language times to ISO8601 (e.g., "6pm today" → appropriate datetime).
     - Confirm the scheduled time after scheduling.

  IMPORTANT:
  - NEVER write text before a tool call.
  - For music results: NEVER include URLs, track names, or album names in your response text.
  - For simple greetings, respond naturally WITHOUT tools.
  - Keep responses VERY short (1-2 sentences max) - this is mobile chat.
  """

  @doc """
  Process a message and return streaming chunks via callback.
  """
  def stream_response(user_message, callback, opts \\ []) do
    conversation_history = Keyword.get(opts, :history, [])
    image_urls = Keyword.get(opts, :images, [])
    user_id = Keyword.get(opts, :user_id, nil)
    chat_id = Keyword.get(opts, :chat_id, nil)
    system_prompt = Keyword.get(opts, :system_prompt, @system_prompt)
    enabled_tools = Keyword.get(opts, :enabled_tools, available_tool_names())
    tools = filter_tools(enabled_tools)

    messages = build_messages(conversation_history, user_message, image_urls)

    case call_claude_with_tools(messages, callback, 0, "", user_id, system_prompt, tools, chat_id) do
      {:ok, final_response} -> {:ok, final_response}
      {:error, reason} -> {:error, reason}
    end
  end

  def available_tools do
    (@tools ++ GroupAgent.standalone_available_tools())
    |> Enum.uniq_by(& &1.name)
  end

  def available_tool_names, do: Enum.map(available_tools(), & &1.name)

  @doc """
  Quick non-streaming completion for simple tasks like title generation.
  Uses Claude haiku for speed.
  """
  def quick_completion(prompt) do
    api_key = System.get_env("ANTHROPIC_API_KEY") || System.get_env("CLAUDE_API_KEY")

    if is_nil(api_key) do
      {:error, "No API key configured"}
    else
      body = Jason.encode!(%{
        model: "claude-3-haiku-20240307",
        max_tokens: 100,
        messages: [%{role: "user", content: prompt}]
      })

      headers = [
        {"content-type", "application/json"},
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"}
      ]

      request = Finch.build(:post, @claude_api, headers, body)

      case Finch.request(request, Vibe.Finch, receive_timeout: 10_000) do
        {:ok, %{status: 200, body: resp_body}} ->
          case Jason.decode(resp_body) do
            {:ok, %{"content" => [%{"text" => text} | _]}} ->
              {:ok, text}
            _ ->
              {:error, "Failed to parse response"}
          end
        {:ok, %{status: status, body: body}} ->
          Logger.error("Claude API error: #{status} - #{body}")
          {:error, "API error: #{status}"}
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_messages(history, user_message, image_urls) do
    # Convert history to Claude format
    history_messages = Enum.map(history, fn msg ->
      %{
        role: msg["role"] || msg[:role],
        content: msg["content"] || msg[:content]
      }
    end)

    # Build current message with optional images
    current_content = if Enum.empty?(image_urls) do
      user_message
    else
      # Multi-modal message with images
      image_blocks = Enum.map(image_urls, fn url ->
        %{
          type: "image",
          source: %{
            type: "url",
            url: url
          }
        }
      end)

      text_block = %{type: "text", text: user_message}
      image_blocks ++ [text_block]
    end

    history_messages ++ [%{role: "user", content: current_content}]
  end

  defp call_claude_with_tools(
         messages,
         callback,
         depth \\ 0,
         _buffered_text \\ "",
         user_id \\ nil,
         system_prompt \\ @system_prompt,
         tools \\ nil,
         chat_id \\ nil
       ) do
    tools = tools || available_tools()

    if depth > 3 do
      # Reduced max depth - no retries, just fail fast
      {:error, "Max tool depth reached"}
    else
      api_key = System.get_env("ANTHROPIC_API_KEY") || System.get_env("CLAUDE_API_KEY")

      unless api_key do
        {:error, "ANTHROPIC_API_KEY not configured"}
      else
        body = Jason.encode!(%{
          model: @claude_model,
          max_tokens: 4096,
          system: system_prompt,
          tools: tools,
          messages: messages,
          stream: true
        })

        headers = [
          {"Content-Type", "application/json"},
          {"x-api-key", api_key},
          {"anthropic-version", "2023-06-01"}
        ]

        # Always defer streaming until tools complete - no intro text should be shown
        # We only stream the FINAL response after all tool calls are done
        stream_text = false

        case stream_claude_response(body, headers, callback, stream_text: stream_text) do
          {:tool_use, tool_calls, partial_response} ->
            # Execute tools first (this emits progress + tool_result events)
            tool_results = execute_tools(tool_calls, callback, user_id, chat_id)

            # Add assistant response and tool results to messages
            new_messages = messages ++ [
              %{role: "assistant", content: partial_response},
              %{role: "user", content: tool_results}
            ]

            # Recurse to get final response - don't pass any buffered intro text
            call_claude_with_tools(new_messages, callback, depth + 1, "", user_id, system_prompt, tools, chat_id)

          {:ok, response} ->
            # Final turn - stream the complete response now
            callback.(%{type: :text, content: response})
            {:ok, response}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp get_text_from_content(blocks) when is_list(blocks) do
    Enum.find_value(blocks, fn
      %{type: "text", text: text} -> text
      _ -> nil
    end)
  end
  defp get_text_from_content(_), do: ""

  defp stream_claude_response(body, headers, callback, opts \\ []) do
    stream_text = Keyword.get(opts, :stream_text, true)
    # Using Finch for streaming HTTP
    request = Finch.build(:post, @claude_api, headers, body)

    result = Finch.stream(request, Vibe.Finch, %{text: "", tool_calls: [], current_tool_index: -1, stop_reason: nil}, fn
      {:status, status}, acc ->
        Map.put(acc, :status, status)

      {:headers, resp_headers}, acc ->
        Map.put(acc, :headers, resp_headers)

      {:data, data}, acc ->
        # Parse SSE events
        events = parse_sse_events(data)

        Enum.reduce(events, acc, fn event, inner_acc ->
          case event do
            %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}} ->
              # Stream text to client ONLY if enabled for this turn
              if stream_text do
                callback.(%{type: :text, content: text})
              end
              Map.update(inner_acc, :text, text, &(&1 <> text))

            %{"type" => "content_block_start", "content_block" => %{"type" => "tool_use"} = tool} ->
              # Start a new tool, store it with empty input string
              new_tool = Map.put(tool, "input_json", "")
              new_index = length(inner_acc.tool_calls)
              inner_acc
              |> Map.update(:tool_calls, [new_tool], &(&1 ++ [new_tool]))
              |> Map.put(:current_tool_index, new_index)

            %{"type" => "content_block_delta", "delta" => %{"type" => "input_json_delta", "partial_json" => json}} ->
              # Append JSON chunk to current tool's input_json
              idx = inner_acc.current_tool_index
              if idx >= 0 do
                updated_tools = List.update_at(inner_acc.tool_calls, idx, fn tool ->
                  Map.update(tool, "input_json", json, &(&1 <> json))
                end)
                Map.put(inner_acc, :tool_calls, updated_tools)
              else
                inner_acc
              end

            %{"type" => "message_delta", "delta" => %{"stop_reason" => reason}} ->
              Map.put(inner_acc, :stop_reason, reason)

            _ ->
              inner_acc
          end
        end)
    end)

    case result do
      {:ok, final_acc} ->
        case final_acc.stop_reason do
          "tool_use" ->
            # Parse inputs for each tool
            tools_with_input = Enum.map(final_acc.tool_calls, fn tool ->
              input = case Jason.decode(tool["input_json"] || "{}") do
                {:ok, parsed} -> parsed
                _ -> %{}
              end
              Map.put(tool, "input", input)
            end)

            {:tool_use, tools_with_input, build_content_blocks(final_acc)}

          _ ->
            {:ok, final_acc.text}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_sse_events(data) do
    data
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(fn line ->
      line
      |> String.replace_prefix("data: ", "")
      |> Jason.decode()
      |> case do
        {:ok, parsed} -> parsed
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp build_content_blocks(acc) do
    blocks = []

    blocks = if acc.text != "" do
      [%{type: "text", text: acc.text} | blocks]
    else
      blocks
    end

    # Each tool now has its own input_json field
    blocks = Enum.reduce(acc.tool_calls, blocks, fn tool, b ->
      input = case Jason.decode(tool["input_json"] || "{}") do
        {:ok, parsed} -> parsed
        _ -> %{}
      end

      [%{
        type: "tool_use",
        id: tool["id"],
        name: tool["name"],
        input: input
      } | b]
    end)

    Enum.reverse(blocks)
  end

  defp execute_tools(tool_calls, callback, user_id \\ nil, chat_id \\ nil) do
    Enum.map(tool_calls, fn tool ->
      tool_name = tool["name"]
      tool_input = tool["input"] || %{}

      # Send progress IMMEDIATELY (before any text)
      label = case tool_name do
        "search_music" ->
           q = tool_input["query"] || "music"
           "Searching for '#{q}'..."
        "search_google" -> "Searching the web..."
        "analyze_image" -> "Analyzing image..."
        "analyze_document" -> "Reading document..."
        "create_document" -> "Preparing document..."
        "find_rows" -> "Inspecting rows..."
        "edit_rows" -> "Updating rows..."
        "delete_rows" -> "Deleting rows..."
        "export_rows" -> "Exporting file..."
        "delete_document" -> "Removing document..."
        "post_to_channel" -> "Posting to channel..."
        "get_channel_analytics" -> "Fetching channel analytics..."
        "schedule_channel_post" -> "Scheduling post..."
        _ -> "Working..."
      end
      callback.(%{type: :progress, label: label, tool: tool_name, status: "running"})

      # Execute the tool
      start_time = System.monotonic_time(:millisecond)

      result = case tool_name do
        "search_music" -> Vibe.AI.Tools.Music.search(tool["input"])
        "search_google" -> Vibe.AI.Tools.Search.google(tool["input"])
        "analyze_image" -> Vibe.AI.Tools.Vision.analyze(tool["input"])
        "analyze_document" -> Vibe.AI.Tools.Document.analyze(tool["input"])
        name when name in GroupAgent.standalone_tool_names() -> GroupAgent.execute_standalone_tool(name, tool["input"], user_id, chat_id)
        "post_to_channel" -> Vibe.AI.Tools.Channel.post_to_channel(tool["input"], user_id)
        "get_channel_analytics" -> Vibe.AI.Tools.Channel.get_analytics(tool["input"], user_id)
        "schedule_channel_post" -> Vibe.AI.Tools.Channel.schedule_post(tool["input"], user_id)
        _ -> %{error: "Unknown tool"}
      end

      duration_ms = System.monotonic_time(:millisecond) - start_time
      Logger.info("[Agent] Tool #{tool_name} completed in #{duration_ms}ms")

      # Send tool result with completion status
      callback.(%{
        type: :tool_result,
        tool: tool_name,
        result: result,
        status: "complete",
        duration_ms: duration_ms
      })

      %{
        type: "tool_result",
        tool_use_id: tool["id"],
        content: Jason.encode!(result)
      }
    end)
  end

  defp filter_tools(enabled_tools) do
    allowed = MapSet.new(List.wrap(enabled_tools) |> Enum.map(&to_string/1))
    Enum.filter(available_tools(), fn tool -> MapSet.member?(allowed, tool.name) end)
  end
end
