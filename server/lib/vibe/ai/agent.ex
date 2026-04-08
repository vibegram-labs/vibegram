defmodule Vibe.AI.Agent do
  @moduledoc """
  AI Agent with tool-use capabilities.
  Tools: Music Search, Google Search, Image/Document Analysis
  """

  import Ecto.Query, warn: false

  require Logger

  alias Vibe.Agent, as: AgentSchema
  alias Vibe.AgentEvent
  alias Vibe.AgentEventThread
  alias Vibe.Agents
  alias Vibe.AI.AgentRuntime
  alias Vibe.AI.GroupAgent
  alias Vibe.AI.SubagentRegistry
  alias Vibe.Repo

  @claude_api "https://api.anthropic.com/v1/messages"
  @claude_model "claude-haiku-4-5-20251001"
  @always_available_tool_names ~w[
    query_event_inbox
    configure_event_inbox
    get_current_agent_config
    update_current_agent_config
  ]

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
    },
    %{
      name: "query_event_inbox",
      description:
        "Look up the agent's received notification/event inbox for a live timeframe such as today, yesterday, last 4h, daily, or a recent period. Use this before answering questions about past notifications, counts, times, or related received items.",
      input_schema: %{
        type: "object",
        properties: %{
          timeframe: %{
            type: "string",
            description: "Time window to inspect, such as today, yesterday, last 4h, last 24h, or last 7d"
          },
          source: %{type: "string", description: "Optional source filter, such as tradeai"},
          event_type: %{type: "string", description: "Optional event type filter"},
          limit: %{type: "integer", description: "Maximum matching events to return, default 25"},
          query: %{
            type: "string",
            description: "Optional free-form intent note for the lookup, such as trades opened yesterday"
          }
        }
      }
    },
    %{
      name: "configure_event_inbox",
      description:
        "Configure how incoming external events are surfaced in chat. Use this when the user asks for normal per-event delivery or batched summaries like every 4h or daily.",
      input_schema: %{
        type: "object",
        properties: %{
          mode: %{
            type: "string",
            enum: ["per_event", "batched_summary"],
            description: "per_event posts each event as it arrives; batched_summary stores events and posts summaries on the chosen cadence."
          },
          cadence: %{
            type: "string",
            enum: ["4h", "daily"],
            description: "Summary cadence when mode is batched_summary."
          }
        },
        required: ["mode"]
      }
    },
    %{
      name: "call_connected_app",
      description:
        "Call a configured connected app action for website, business, admin, or app-side data and changes. Only use actions that the agent's connected app explicitly exposes.",
      input_schema: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            description: "The connected app action id, such as website.summary or waitlist.summary"
          },
          params: %{
            type: "object",
            description: "Action parameters to send to the connected app",
            additionalProperties: true
          },
          integration_id: %{
            type: "string",
            description: "Optional specific integration id when multiple connected apps are configured"
          },
          integration_name: %{
            type: "string",
            description: "Optional specific integration name when multiple connected apps are configured"
          }
        },
        required: ["action"]
      }
    },
    %{
      name: "get_current_agent_config",
      description:
        "Read the current standalone agent's live config for the owner, including prompt, ids, status, tools, output modes, destination chats, and endpoints. Prefer this for simple questions about the agent you are already talking to.",
      input_schema: %{
        type: "object",
        properties: %{
          include_prompt: %{
            type: "boolean",
            description: "When true, include the full saved system prompt. Defaults to true."
          }
        }
      }
    },
    %{
      name: "update_current_agent_config",
      description:
        "Update the current standalone agent directly for simple one-agent changes such as prompt, name, persona, welcome message, voice profile, or status. Prefer this over delegate_to_subagent when the user is changing the agent they are already chatting with.",
      input_schema: %{
        type: "object",
        properties: %{
          display_name: %{type: "string", description: "Updated display name."},
          system_prompt: %{type: "string", description: "Updated system prompt."},
          persona: %{type: "string", description: "Updated persona."},
          welcome_message: %{type: "string", description: "Updated welcome message."},
          voice_profile: %{type: "string", description: "Updated voice profile."},
          status: %{
            type: "string",
            enum: ["draft", "published", "disabled"],
            description: "Optional status change for the current agent."
          }
        }
      }
    },
    %{
      name: "delegate_to_subagent",
      description:
        "Delegate a task to one of Vibe AI's internal subagents when the request is about agent setup, existing agents, integrations, prompts, publication state, agent deletion, or needs a specialized worker. This tool gives you access to those specialist capabilities; do not claim you lack access before using it.",
      input_schema: %{
        type: "object",
        properties: %{
          subagent_id: %{
            type: "string",
            enum: ["builder_assistant", "integration_advisor", "music_specialist", "document_specialist"],
            description: "Which internal specialist should handle the task."
          },
          task: %{
            type: "string",
            description: "The delegated task or question for that specialist."
          }
        },
        required: ["subagent_id", "task"]
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

  9. query_event_inbox: Use for questions about the agent's received notifications or past events.
     - Use this BEFORE answering questions like:
       * "How many trades did I have yesterday?"
       * "When were they opened?"
       * "Summarize the last 4 hours of notifications"
       * "Show me related messages from that inbox"
     - If you are not certain about past events, counts, timing, or related notifications, look them up first instead of guessing from memory.

  10. configure_event_inbox: Use when the user wants notification mode changes.
      - Use this for requests like:
        * "Don't reply to every event"
        * "Summarize these daily"
        * "Switch back to normal event bubbles"
      - `per_event` means each event posts as a chat bubble.
      - `batched_summary` means events are stored and summarized on the selected cadence.

  11. call_connected_app: Use when the user asks about a connected website, admin dashboard, waitlist, business metrics, catalog, orders, or wants the connected app/backend to do something.
      - ALWAYS provide the `action` parameter.
      - Put request arguments inside `params` as a JSON object.
      - Only use actions explicitly listed in the connected-app section of the system prompt or returned by the tool itself.
      - If the user asks for website traffic, conversions, waitlist numbers, product counts, or to change something in the connected app, prefer this tool over guessing.

  12. get_current_agent_config: Use for simple live questions about the agent you are already talking to.
      - Use this for requests like:
        * "what is my current prompt?"
        * "what tools do you have enabled?"
        * "what is this agent's id or invoke url?"
        * "is incoming chat enabled?"
      - Prefer this over delegate_to_subagent when the request is only about the current agent's existing state.

  13. update_current_agent_config: Use for simple direct edits to the agent you are already talking to.
      - Use this for requests like:
        * "change your prompt to ..."
        * "rename yourself to ..."
        * "update your welcome message"
        * "switch your status to draft/published/disabled"
      - Prefer this over delegate_to_subagent when the request is a one-agent edit and you already have enough information.

  14. delegate_to_subagent: Use when the request is better handled by an internal specialist.
     - builder_assistant: multi-step agent creation, complex reconfiguration, agent deletion, or builder-style workflows spanning more than one step.
     - integration_advisor: invoke URLs, events URLs, secrets, attached vibe chat ids, and backend integration questions when the direct current-agent config tools are not enough.
     - music_specialist: focused music help when the request is mostly about discovery/playback.
     - document_specialist: focused research, web lookup, image analysis, or document analysis.
     - Do not delegate simple current-agent reads or one-field edits that `get_current_agent_config` or `update_current_agent_config` can handle directly.
     - If the user already gave a clear agent workflow and asks for setup or integration details, delegate with an execution-oriented task. Do not keep the conversation stuck on naming, formatting, or cosmetic choices.
     - Ask follow-up questions only when a real blocker remains, such as create-vs-existing ambiguity, missing destination chat requirements, or unavailable secrets.
     - ALWAYS provide both "subagent_id" and "task".
     - Do not use this for simple chat when your own tools already solve it directly.
     - Never say you do not have the tool if delegation can solve it.
     - Never tell the user to reach out to a specialist; you already can delegate to them yourself.
     - After delegation succeeds, answer from the specialist result as if it is your own checked result.

  IMPORTANT:
  - NEVER write text before a tool call.
  - For music results: NEVER include URLs, track names, or album names in your response text.
  - If a user asks for live agent configuration, current inbox mode, or historical notification facts, use the live lookup/config tools first.
  - For simple current-agent prompt or name changes, use `update_current_agent_config` instead of delegating.
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
    requester_user_id = Keyword.get(opts, :requester_user_id, nil)
    chat_id = Keyword.get(opts, :chat_id, nil)
    agent_id = Keyword.get(opts, :agent_id, nil)
    system_prompt = Keyword.get(opts, :system_prompt, @system_prompt)
    enabled_tools = Keyword.get(opts, :enabled_tools, available_tool_names())
    max_tokens = Keyword.get(opts, :max_tokens, 4096)
    max_depth = Keyword.get(opts, :max_depth, 3)
    tools = filter_tools(enabled_tools)

    messages = build_messages(conversation_history, user_message, image_urls)

    AgentRuntime.run(
      messages,
      %AgentRuntime.Config{
        model: @claude_model,
        max_tokens: max_tokens,
        max_depth: max_depth,
        system_prompt: system_prompt,
        tools: tools,
        state: %{user_id: user_id, requester_user_id: requester_user_id, chat_id: chat_id, agent_id: agent_id},
        callback: callback,
        stream_text?: true,
        execute_tools: &execute_tools_runtime/3,
        missing_api_key_error: "ANTHROPIC_API_KEY not configured",
        depth_error: "Max tool depth reached",
        request_label: "Agent"
      }
    )
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

  defp execute_tools_runtime(tool_calls, state, callback) do
    user_id = Map.get(state, :user_id)
    requester_user_id = Map.get(state, :requester_user_id)
    chat_id = Map.get(state, :chat_id)
    agent_id = Map.get(state, :agent_id)
    {execute_tools(tool_calls, callback, user_id, requester_user_id, chat_id, agent_id), state}
  end

  defp execute_tools(tool_calls, callback, user_id, requester_user_id, chat_id, agent_id) do
    # Send all progress labels immediately so the UI shows activity
    Enum.each(tool_calls, fn tool ->
      tool_name = tool["name"]
      tool_input = tool["input"] || %{}

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
        "query_event_inbox" -> "Reviewing the inbox..."
        "configure_event_inbox" -> "Updating inbox mode..."
        "call_connected_app" -> "Checking the connected app..."
        "get_current_agent_config" -> "Reading this agent's config..."
        "update_current_agent_config" -> "Updating this agent..."
        "delegate_to_subagent" ->
          SubagentRegistry.progress_label(
            tool_input["subagent_id"] || "",
            tool_input["task"]
          )
        _ -> "Working..."
      end
      callback.(%{type: :progress, label: label, tool: tool_name, status: "running"})
    end)

    # Run tool calls in parallel using Task.async for concurrent execution
    tasks =
      Enum.map(tool_calls, fn tool ->
        Task.async(fn ->
          execute_single_tool(tool, callback, user_id, requester_user_id, chat_id, agent_id)
        end)
      end)

    # Await all tasks with a generous timeout (120s per tool)
    Enum.map(tasks, fn task ->
      case Task.yield(task, 120_000) || Task.shutdown(task) do
        {:ok, result} -> result
        nil ->
          Logger.error("[Agent] Tool execution timed out after 120s")
          %{type: "tool_result", tool_use_id: "unknown", content: Jason.encode!(%{error: "Tool timed out"})}
      end
    end)
  end

  defp execute_single_tool(tool, callback, user_id, requester_user_id, chat_id, agent_id) do
    tool_name = tool["name"]
    tool_input = tool["input"] || %{}
    start_time = System.monotonic_time(:millisecond)

    result =
      cond do
        tool_name == "search_music" ->
          Vibe.AI.Tools.Music.search(tool["input"])

        tool_name == "search_google" ->
          Vibe.AI.Tools.Search.google(tool["input"])

        tool_name == "analyze_image" ->
          Vibe.AI.Tools.Vision.analyze(tool["input"])

        tool_name == "analyze_document" ->
          Vibe.AI.Tools.Document.analyze(tool["input"])

        tool_name in GroupAgent.standalone_tool_names() ->
          GroupAgent.execute_standalone_tool(tool_name, tool["input"], user_id, chat_id)

        tool_name == "post_to_channel" ->
          Vibe.AI.Tools.Channel.post_to_channel(tool["input"], user_id)

        tool_name == "get_channel_analytics" ->
          Vibe.AI.Tools.Channel.get_analytics(tool["input"], user_id)

        tool_name == "schedule_channel_post" ->
          Vibe.AI.Tools.Channel.schedule_post(tool["input"], user_id)

        tool_name == "query_event_inbox" ->
          query_event_inbox(tool_input, agent_id, requester_user_id)

        tool_name == "configure_event_inbox" ->
          configure_event_inbox(tool_input, agent_id, requester_user_id)

        tool_name == "call_connected_app" ->
          Vibe.AI.Tools.ConnectedApp.invoke(tool_input, agent_id, requester_user_id)

        tool_name == "get_current_agent_config" ->
          get_current_agent_config(tool_input, agent_id, requester_user_id)

        tool_name == "update_current_agent_config" ->
          update_current_agent_config(tool_input, agent_id, requester_user_id)

        tool_name == "delegate_to_subagent" ->
          case SubagentRegistry.run(
                 tool_input["subagent_id"],
                 tool_input["task"],
                 user_id: user_id,
                 requester_user_id: requester_user_id,
                 chat_id: chat_id,
                 active_agent_id: agent_id,
                 callback: callback
               ) do
            {:ok, payload} -> payload
            {:error, reason} -> %{"ok" => false, "error" => inspect(reason)}
          end

        true ->
          %{error: "Unknown tool"}
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
  end

  defp query_event_inbox(input, agent_id, requester_user_id) do
    with {:ok, agent} <- resolve_owned_agent(agent_id, requester_user_id) do
      timeframe = resolve_event_timeframe(input["timeframe"] || input["window"] || input["period"])
      source_filter = normalize_tool_string(input["source"])
      event_type_filter = normalize_tool_string(input["event_type"] || input["eventType"])
      limit = normalize_limit(input["limit"], 25, 60)

      query =
        from e in AgentEvent,
          join: t in AgentEventThread,
          on: t.id == e.thread_id,
          where:
            e.agent_id == ^agent.id and
              e.occurred_at >= ^timeframe.since and
              e.occurred_at <= ^timeframe.until,
          order_by: [desc: e.occurred_at, desc: e.inserted_at]

      query =
        if is_binary(source_filter) do
          from [e, _t] in query, where: e.source == ^source_filter
        else
          query
        end

      query =
        if is_binary(event_type_filter) do
          from [e, _t] in query, where: e.event_type == ^event_type_filter
        else
          query
        end

      events =
        query
        |> limit(^limit)
        |> select([e, t], %{
          id: e.id,
          message_id: e.message_id,
          occurred_at: e.occurred_at,
          source: e.source,
          event_type: e.event_type,
          title: e.title,
          text: e.text,
          payload: e.payload,
          thread_id: t.id,
          thread_key: t.thread_key,
          thread_title: t.title
        })
        |> Repo.all()
      related_message_ids = events |> Enum.map(& &1.message_id) |> Enum.filter(&is_binary/1) |> Enum.uniq()

      %{
        "ok" => true,
        "timeframe" => %{
          "label" => timeframe.label,
          "since" => DateTime.to_iso8601(timeframe.since),
          "until" => DateTime.to_iso8601(timeframe.until)
        },
        "mode" => current_event_inbox_mode(agent),
        "summary_window_hours" => current_event_inbox_window_hours(agent),
        "total_events" => length(events),
        "source_counts" => count_by(events, & &1.source),
        "event_type_counts" => count_by(events, & &1.event_type),
        "events" =>
          Enum.map(events, fn event ->
            %{
              "id" => event.id,
              "message_id" => event.message_id,
              "occurred_at" => DateTime.to_iso8601(event.occurred_at),
              "source" => event.source,
              "event_type" => event.event_type,
              "title" => event.title,
              "text" => event.text,
              "thread_id" => event.thread_id,
              "thread_key" => event.thread_key,
              "thread_title" => event.thread_title,
              "payload" => condensed_payload(event.payload)
            }
          end),
        "summary" => build_event_inbox_summary(events, timeframe.label, source_filter, event_type_filter),
        "related_message_ids" => related_message_ids,
        "related_title" => related_messages_title(length(related_message_ids)),
        "related_subtitle" =>
          if(related_message_ids == [], do: nil, else: "Tap to review the underlying messages")
      }
    else
      {:error, reason} ->
        %{"ok" => false, "error" => inbox_error_message(reason)}
    end
  end

  defp configure_event_inbox(input, agent_id, requester_user_id) do
    with {:ok, agent} <- resolve_owned_agent(agent_id, requester_user_id),
         mode <- normalize_event_inbox_mode(input["mode"]),
         {:ok, next_rules} <- updated_event_inbox_rules(agent.approval_rules || %{}, mode, input["cadence"]) do
      case Agents.update_agent(agent, %{"approval_rules" => next_rules}, requester_user_id) do
        {:ok, updated_agent} ->
          %{
            "ok" => true,
            "mode" => current_event_inbox_mode(updated_agent),
            "summary_window_hours" => current_event_inbox_window_hours(updated_agent),
            "summary" => event_inbox_config_summary(updated_agent)
          }

        {:error, reason} ->
          %{"ok" => false, "error" => inspect(reason)}
      end
    else
      {:error, reason} ->
        %{"ok" => false, "error" => inbox_error_message(reason)}
    end
  end

  defp get_current_agent_config(input, agent_id, requester_user_id) do
    include_prompt =
      case Map.get(input, "include_prompt") do
        false -> false
        "false" -> false
        "0" -> false
        0 -> false
        _ -> true
      end

    with {:ok, agent} <- resolve_owned_agent(agent_id, requester_user_id) do
      %{"ok" => true, "agent" => current_agent_config_payload(agent, include_prompt)}
    else
      {:error, reason} ->
        %{"ok" => false, "error" => inbox_error_message(reason)}
    end
  end

  defp update_current_agent_config(input, agent_id, requester_user_id) do
    with {:ok, agent} <- resolve_owned_agent(agent_id, requester_user_id),
         {:ok, attrs} <- current_agent_update_attrs(input),
         {:ok, updated_agent} <- persist_current_agent_update(agent, attrs, requester_user_id) do
      %{
        "ok" => true,
        "message" => "Agent updated.",
        "agent" => current_agent_config_payload(updated_agent, true)
      }
    else
      {:error, :no_changes_requested} ->
        %{"ok" => false, "error" => "No agent changes were requested."}

      {:error, :empty_system_prompt} ->
        %{"ok" => false, "error" => "System prompt cannot be empty."}

      {:error, reason} ->
        %{"ok" => false, "error" => inbox_error_message(reason)}
    end
  end

  defp persist_current_agent_update(agent, attrs, requester_user_id) do
    status = Map.get(attrs, "status")
    update_attrs = Map.delete(attrs, "status")

    with {:ok, updated_agent} <-
           if(map_size(update_attrs) > 0,
             do: Agents.update_agent(agent, update_attrs, requester_user_id),
             else: {:ok, agent}
           ) do
      case status do
        nil ->
          {:ok, updated_agent}

        "published" ->
          Agents.publish_agent(updated_agent, requester_user_id)

        "draft" ->
          Agents.update_agent(updated_agent, %{"status" => "draft"}, requester_user_id)

        "disabled" ->
          Agents.update_agent(updated_agent, %{"status" => "disabled"}, requester_user_id)

        _ ->
          {:error, :invalid_status}
      end
    end
  end

  defp current_agent_update_attrs(input) when is_map(input) do
    attrs =
      %{}
      |> maybe_put_trimmed(input, "display_name")
      |> maybe_put_trimmed(input, "persona")
      |> maybe_put_trimmed(input, "welcome_message")
      |> maybe_put_trimmed(input, "voice_profile")
      |> maybe_put_status(input)

    case Map.fetch(input, "system_prompt") do
      {:ok, prompt} when is_binary(prompt) ->
        case String.trim(prompt) do
          "" -> {:error, :empty_system_prompt}
          trimmed -> {:ok, Map.put(attrs, "system_prompt", trimmed)}
        end

      {:ok, _other} ->
        {:error, :empty_system_prompt}

      :error ->
        if map_size(attrs) == 0, do: {:error, :no_changes_requested}, else: {:ok, attrs}
    end
  end

  defp current_agent_update_attrs(_input), do: {:error, :no_changes_requested}

  defp maybe_put_trimmed(attrs, input, key) do
    case Map.fetch(input, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> attrs
          trimmed -> Map.put(attrs, key, trimmed)
        end

      _ ->
        attrs
    end
  end

  defp maybe_put_status(attrs, input) do
    case Map.get(input, "status") do
      value when value in ["draft", "published", "disabled"] -> Map.put(attrs, "status", value)
      _ -> attrs
    end
  end

  defp current_agent_config_payload(agent, include_prompt) do
    payload = Agents.agent_payload(agent)
    attached_chats = Enum.map(payload.attachedChats || [], &chat_payload/1)

    default_destination_chat =
      attached_chats
      |> Enum.find(fn chat -> chat["chat_id"] == payload.defaultDestinationChatId end)
      |> case do
        nil when is_binary(payload.defaultDestinationChatId) ->
          %{"chat_id" => payload.defaultDestinationChatId}

        found ->
          found
      end

    %{
      "id" => payload.id,
      "display_name" => payload.displayName,
      "username" => payload.username,
      "identifier" => payload.username || payload.id,
      "status" => payload.status,
      "persona" => payload.persona,
      "welcome_message" => payload.welcomeMessage,
      "enabled_tools" => payload.enabledTools || [],
      "output_modes" => payload.outputModes || [],
      "voice_profile" => payload.voiceProfile,
      "callback_url" => payload.callbackUrl,
      "api_base_url" => public_base_url(),
      "invoke_url" => build_invoke_url(agent),
      "events_url" => build_events_url(agent),
      "default_destination_chat_id" => payload.defaultDestinationChatId,
      "default_destination_chat" => default_destination_chat,
      "attached_chats" => attached_chats,
      "incoming_chat_enabled" => Agents.incoming_chat_enabled?(agent),
      "event_inbox_mode" => current_event_inbox_mode(agent),
      "summary_window_hours" => current_event_inbox_window_hours(agent),
      "prompt_status" => if(String.trim(agent.system_prompt || "") == "", do: "Missing", else: "Custom"),
      "prompt_preview" => condensed_prompt_preview(agent.system_prompt)
    }
    |> maybe_put("system_prompt", if(include_prompt, do: agent.system_prompt, else: nil))
  end

  defp chat_payload(%{} = chat) do
    %{}
    |> maybe_put("chat_id", Map.get(chat, :chatId) || Map.get(chat, "chatId"))
    |> maybe_put("type", Map.get(chat, :type) || Map.get(chat, "type"))
    |> maybe_put("name", Map.get(chat, :name) || Map.get(chat, "name"))
    |> maybe_put("avatar_url", Map.get(chat, :avatarUrl) || Map.get(chat, "avatarUrl"))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp condensed_prompt_preview(prompt) when is_binary(prompt) do
    prompt
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> case do
      "" -> nil
      text -> String.slice(text, 0, 180)
    end
  end

  defp condensed_prompt_preview(_prompt), do: nil

  defp build_invoke_url(%AgentSchema{id: id}) do
    path = "/api/agents/#{id}/invoke"
    append_public_path(path)
  end

  defp build_events_url(%AgentSchema{id: id}) do
    path = "/api/agents/#{id}/events"
    append_public_path(path)
  end

  defp append_public_path(path) do
    case public_base_url() do
      "" -> path
      base -> String.trim_trailing(base, "/") <> path
    end
  end

  defp public_base_url do
    System.get_env("PUBLIC_BASE_URL") ||
      System.get_env("API_BASE_URL") ||
      endpoint_url()
  end

  defp endpoint_url do
    try do
      VibeWeb.Endpoint.url()
    rescue
      _ -> ""
    end
  end

  defp resolve_owned_agent(agent_id, requester_user_id) when is_binary(agent_id) and is_binary(requester_user_id) do
    case Agents.get_agent(agent_id, requester_user_id) do
      %AgentSchema{} = agent -> {:ok, agent}
      nil -> {:error, :agent_not_available}
    end
  end

  defp resolve_owned_agent(_agent_id, _requester_user_id), do: {:error, :owner_lookup_required}

  defp resolve_event_timeframe(raw) do
    now = DateTime.utc_now()
    normalized = normalize_tool_string(raw) || "last 24h"

    case normalized do
      "today" ->
        date = Date.utc_today()
        %{label: "today", since: DateTime.new!(date, ~T[00:00:00], "Etc/UTC"), until: now}

      "yesterday" ->
        date = Date.add(Date.utc_today(), -1)

        %{
          label: "yesterday",
          since: DateTime.new!(date, ~T[00:00:00], "Etc/UTC"),
          until: DateTime.new!(date, ~T[23:59:59], "Etc/UTC")
        }

      "daily" ->
        %{label: "last 24h", since: DateTime.add(now, -24 * 3600, :second), until: now}

      "last 4h" ->
        %{label: "last 4h", since: DateTime.add(now, -4 * 3600, :second), until: now}

      "last 24h" ->
        %{label: "last 24h", since: DateTime.add(now, -24 * 3600, :second), until: now}

      "last 7d" ->
        %{label: "last 7d", since: DateTime.add(now, -7 * 24 * 3600, :second), until: now}

      other ->
        case Regex.run(~r/^last\s+(\d+)\s*(h|hr|hrs|hour|hours|d|day|days)$/u, other) do
          [_, amount_raw, unit] ->
            amount = String.to_integer(amount_raw)

            seconds =
              case unit do
                unit when unit in ["d", "day", "days"] -> amount * 24 * 3600
                _ -> amount * 3600
              end

            %{label: other, since: DateTime.add(now, -seconds, :second), until: now}

          _ ->
            %{label: "last 24h", since: DateTime.add(now, -24 * 3600, :second), until: now}
        end
    end
  end

  defp build_event_inbox_summary(events, timeframe_label, source_filter, event_type_filter) do
    headline =
      "Found #{length(events)} event#{if length(events) == 1, do: "", else: "s"} in #{timeframe_label}."

    filters =
      [
        if(source_filter, do: "Source: #{source_filter}.", else: nil),
        if(event_type_filter, do: "Type: #{event_type_filter}.", else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    timeline =
      events
      |> Enum.take(5)
      |> Enum.reverse()
      |> Enum.map(fn event ->
        "#{format_event_time(event.occurred_at)} #{event.title || event.event_type}"
      end)
      |> case do
        [] -> nil
        lines -> "Latest: " <> Enum.join(lines, " | ")
      end

    [headline, filters, timeline]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp format_event_time(%DateTime{} = value) do
    Calendar.strftime(value, "%b %d %H:%M")
  rescue
    _ -> DateTime.to_iso8601(value)
  end

  defp condensed_payload(payload) when is_map(payload) do
    payload
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
    |> Enum.take(10)
    |> Enum.into(%{})
  end

  defp condensed_payload(_), do: %{}

  defp count_by(events, mapper) when is_list(events) do
    events
    |> Enum.reduce(%{}, fn event, acc ->
      key = mapper.(event)

      if is_binary(key) and key != "" do
        Map.update(acc, key, 1, &(&1 + 1))
      else
        acc
      end
    end)
  end

  defp current_event_inbox_mode(%AgentSchema{} = agent) do
    agent.approval_rules
    |> Map.get("event_inbox", %{})
    |> Map.get("mode")
    |> normalize_event_inbox_mode()
  end

  defp current_event_inbox_window_hours(%AgentSchema{} = agent) do
    agent.approval_rules
    |> Map.get("event_inbox", %{})
    |> Map.get("summary_window_hours")
    |> normalize_summary_window_hours()
  end

  defp updated_event_inbox_rules(rules, "per_event", _cadence) do
    {:ok, Map.put(rules, "event_inbox", %{"mode" => "per_event", "summary_window_hours" => 24})}
  end

  defp updated_event_inbox_rules(rules, "batched_summary", cadence) do
    {:ok,
     Map.put(rules, "event_inbox", %{
       "mode" => "batched_summary",
       "summary_window_hours" => normalize_summary_window_hours(cadence)
     })}
  end

  defp updated_event_inbox_rules(_rules, _mode, _cadence), do: {:error, :invalid_mode}

  defp event_inbox_config_summary(%AgentSchema{} = agent) do
    case current_event_inbox_mode(agent) do
      "batched_summary" -> "Inbox mode is batched_summary every #{current_event_inbox_window_hours(agent)}h."
      _ -> "Inbox mode is per_event."
    end
  end

  defp normalize_event_inbox_mode(value) do
    case normalize_tool_string(value) do
      "batched_summary" -> "batched_summary"
      "batched" -> "batched_summary"
      "batch" -> "batched_summary"
      "summary" -> "batched_summary"
      "per_event" -> "per_event"
      "default" -> "per_event"
      "live" -> "per_event"
      _ -> "per_event"
    end
  end

  defp normalize_summary_window_hours(value) do
    case normalize_tool_string(value) do
      "4h" -> 4
      "4" -> 4
      "daily" -> 24
      "24h" -> 24
      "24" -> 24
      _ ->
        case normalize_limit(value, 24, 168) do
          hours when is_integer(hours) and hours > 0 -> hours
          _ -> 24
        end
    end
  end

  defp normalize_limit(value, _default, max_limit) when is_integer(value) do
    min(max(value, 1), max_limit)
  end

  defp normalize_limit(value, default, max_limit) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> normalize_limit(parsed, default, max_limit)
      :error -> default
    end
  end

  defp normalize_limit(_value, default, _max_limit), do: default

  defp normalize_tool_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp normalize_tool_string(_), do: nil

  defp related_messages_title(count) when count <= 1, do: "Related message"
  defp related_messages_title(count), do: "#{count} related messages"

  defp inbox_error_message(:owner_lookup_required), do: "Owner lookup is required for inbox tools."
  defp inbox_error_message(:agent_not_available), do: "This inbox is not available in the current chat."
  defp inbox_error_message(:invalid_mode), do: "That inbox mode is not supported."
  defp inbox_error_message(reason), do: inspect(reason)

  defp filter_tools(enabled_tools) do
    allowed = MapSet.new(List.wrap(enabled_tools) |> Enum.map(&to_string/1))

    Enum.filter(available_tools(), fn tool ->
      MapSet.member?(allowed, tool.name) or tool.name in @always_available_tool_names
    end)
  end
end
