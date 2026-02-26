defmodule Vibe.AI.GroupAgent do
  @moduledoc """
  AI Agent for group/channel chats.
  Handles @vibe mentions, generates responses with per-group custom prompts,
  and manages conversation memory with auto-compaction.
  """

  require Logger

  alias Vibe.Chat.{GroupAgent, GroupAgentMemory, GroupAgentDocument}
  alias Vibe.Repo

  @claude_api "https://api.anthropic.com/v1/messages"
  @claude_model "claude-haiku-4-5-20251001"

  # Well-known UUID for the Vibe AI agent virtual user
  @agent_user_id "00000000-0000-0000-0000-000000000001"
  @agent_username "vibe_ai_agent_0001"

  # Memory thresholds
  @compaction_threshold 50
  @keep_recent_count 10
  @context_message_limit 30
  @uploads_dir "/app/uploads"
  @agent_docs_dir "agent-docs"

  @default_system_prompt """
  You are Vibe AI, a helpful assistant in this group chat.
  Be concise, practical, and context-aware.
  """

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
    },
    %{
      name: "create_document",
      description:
        "Create or edit a formatted document OR editable spreadsheet file scoped to this group. For spreadsheet requests, use format csv (Excel/Google Sheets compatible).",
      input_schema: %{
        type: "object",
        properties: %{
          title: %{type: "string", description: "Document title"},
          body: %{type: "string", description: "Document main content"},
          format: %{
            type: "string",
            enum: [
              "markdown",
              "plain_text",
              "html",
              "json",
              "csv",
              "excel",
              "xlsx",
              "spreadsheet",
              "google_sheet"
            ],
            description: "Output document format. Use csv/excel/spreadsheet/google_sheet for editable table files."
          },
          sections: %{
            type: "array",
            items: %{type: "string"},
            description: "Optional section headings to structure the document"
          },
          columns: %{
            type: "array",
            items: %{type: "string"},
            description: "For spreadsheet output: ordered column headers."
          },
          rows: %{
            type: "array",
            items: %{
              oneOf: [
                %{type: "array", items: %{type: "string"}},
                %{type: "object"}
              ]
            },
            description:
              "For spreadsheet output: row data. Can be arrays aligned to columns, or objects keyed by column name."
          },
          operation: %{
            type: "string",
            enum: ["create_new", "edit_current", "append_rows", "replace_rows", "revert_last"],
            description:
              "Spreadsheet edit operation. Use edit_current/append_rows for ongoing updates; use create_new only when user explicitly asks for a new file."
          }
        },
        required: ["title", "body"]
      }
    }
  ]

  @doc """
  Returns the well-known agent user ID constant.
  """
  def agent_user_id, do: @agent_user_id

  @doc """
  Returns default system prompt text for group agents.
  """
  def default_system_prompt, do: @default_system_prompt

  @doc """
  Returns all available tool definitions for the group agent.
  """
  def available_tools, do: @tools

  @doc """
  Returns all available tool names.
  """
  def available_tool_names, do: Enum.map(@tools, & &1.name)

  @doc """
  Normalize enabled tools list coming from API input/database.
  Falls back to all available tools if list is empty or invalid.
  """
  def normalize_enabled_tools(raw_tools) do
    allowed = MapSet.new(available_tool_names())

    normalized =
      raw_tools
      |> normalize_tools_input()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()
      |> Enum.filter(&MapSet.member?(allowed, &1))

    if normalized == [], do: available_tool_names(), else: normalized
  end

  @doc """
  Generate an enhanced system prompt from short admin input.
  Uses LLM when available and falls back to deterministic prompt text.
  """
  def generate_system_prompt(user_input, enabled_tools \\ nil) do
    trimmed_input =
      user_input
      |> to_string()
      |> String.trim()

    if trimmed_input == "" do
      {:error, :empty_input}
    else
      normalized_tools = normalize_enabled_tools(enabled_tools)
      prompt = build_prompt_generation_instruction(trimmed_input, normalized_tools)

      case Vibe.AI.Agent.quick_completion(prompt) do
        {:ok, generated} ->
          final_prompt = normalize_generated_prompt(generated, trimmed_input)
          {:ok, final_prompt}

        {:error, _reason} ->
          {:ok, fallback_generated_prompt(trimmed_input)}
      end
    end
  end

  @doc """
  Handle an @vibe mention in a group chat.
  Loads agent config, builds context with memory, calls Claude, and broadcasts the response.
  """
  def handle_mention(chat_id, user_message, user_id, metadata \\ %{}) do
    Logger.info("[GroupAgent] handle_mention called chat_id=#{chat_id} user_id=#{user_id} msg_len=#{String.length(user_message)}")

    case GroupAgent.get_enabled_by_chat(chat_id) do
      nil ->
        Logger.info("[GroupAgent] No enabled agent for chat #{chat_id}")
        {:error, :no_agent}

      agent_config ->
        process_mention(chat_id, agent_config, user_message, user_id, metadata)
    end
  end

  defp process_mention(chat_id, agent_config, user_message, user_id, metadata) do
    enabled_tools = normalize_enabled_tools(Map.get(agent_config, :enabled_tools))

    # 1. Load memory
    {:ok, memory} = GroupAgentMemory.get_or_create(chat_id)
    Logger.info("[GroupAgent] Memory loaded for #{chat_id}: #{length(memory.messages)} messages, summary=#{if memory.summary, do: "yes", else: "no"}")

    # 2. Build system prompt with memory + current group document context
    group_document_context = build_group_document_context(chat_id)
    system_prompt = build_system_prompt(agent_config, memory, enabled_tools, group_document_context)

    # 3. Build message history from memory + current message
    messages = build_messages(memory, user_message, metadata)
    Logger.info("[GroupAgent] Calling Claude for #{chat_id}: #{length(messages)} messages, system_prompt_len=#{String.length(system_prompt)}")

    # 4. Call Claude
    case call_claude(messages, system_prompt, user_id, enabled_tools, chat_id) do
      {:ok, response_text} ->
        response =
          maybe_attach_spreadsheet_fallback(
            chat_id,
            user_message,
            response_text,
            enabled_tools,
            user_id
          )

        # 5. Store in memory
        attachment_summary = summarize_attachments_for_memory(metadata)
        stored_user_content =
          user_message
          |> String.trim()
          |> append_attachment_summary_for_storage(attachment_summary)

        GroupAgentMemory.append_message(chat_id, %{
          "role" => "user",
          "content" => stored_user_content,
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

  defp build_system_prompt(agent_config, memory, enabled_tools, group_document_context) do
    base_system_prompt =
      (agent_config.system_prompt || @default_system_prompt)
      |> to_string()
      |> String.trim()

    tool_descriptions =
      @tools
      |> Enum.filter(&(&1.name in enabled_tools))
      |> Enum.map(fn tool -> "- #{tool.name}: #{tool.description}" end)
      |> Enum.join("\n")

    base_prompt = """
    #{base_system_prompt}

    IMPORTANT RULES:
    - You are #{agent_config.name}, an AI assistant in this group chat.
    - Keep responses concise and relevant — this is mobile chat.
    - When using tools, call them IMMEDIATELY without intro text.
    - Spreadsheet behavior is stateful per group chat.
    - Default behavior is to edit the current spreadsheet for this chat.
    - Use operation=create_new only when user explicitly asks for a NEW file/from-scratch sheet.
    - For adding data, prefer operation=append_rows.
    - For corrections, prefer operation=edit_current or replace_rows.
    - If user asks to undo/revert, use operation=revert_last.
    - If user asks for Excel/sheet/spreadsheet/table with rows/columns, call create_document with format csv.
    - When a tool creates/updates a file, respond naturally and state that the file is attached (do not paste raw URLs).
    - You can reference previous conversations from your memory.
    - Address users naturally, referring to the group context.
    - Only use tools that are enabled for this group.
    - If attachments are provided in the current message context, use them.
    - Never claim you cannot create/edit spreadsheet files when create_document is enabled.

    ENABLED TOOLS:
    #{if tool_descriptions == "", do: "- none", else: tool_descriptions}

    CURRENT GROUP DOCUMENT CONTEXT:
    #{group_document_context}
    """

    case memory.summary do
      nil -> base_prompt
      "" -> base_prompt
      summary ->
        base_prompt <> "\n\nConversation Memory (summary of earlier interactions):\n#{summary}\n"
    end
  end

  defp build_group_document_context(chat_id) do
    case GroupAgentDocument.get_current(chat_id) do
      nil ->
        "No active spreadsheet file for this group yet."

      current ->
        columns =
          current.columns
          |> List.wrap()
          |> Enum.join(", ")
          |> default_if_blank("(none)")

        recent_versions =
          chat_id
          |> GroupAgentDocument.list_recent(3)
          |> Enum.map_join("\n", fn doc ->
            "- v#{doc.version} (#{doc.change_type}) #{doc.title} => #{doc.relative_url}"
          end)
          |> default_if_blank("- none")

        """
        Current file:
        - version: #{current.version}
        - title: #{current.title}
        - format: #{current.format}
        - rows: #{current.row_count}
        - columns: #{columns}
        - file_url: #{current.file_url}

        Recent versions:
        #{recent_versions}
        """
        |> String.trim()
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

    image_urls = normalize_url_list(Map.get(metadata, "image_urls", []))
    document_urls = normalize_url_list(Map.get(metadata, "document_urls", []))

    attachment_context = build_attachment_context(image_urls, document_urls)
    merged_message_text = append_attachment_context(current_message, attachment_context)

    # Build current message with optional images
    current_content = if Enum.empty?(image_urls) do
      merged_message_text
    else
      image_blocks = Enum.map(image_urls, fn url ->
        %{type: "image", source: %{type: "url", url: url}}
      end)
      image_blocks ++ [%{type: "text", text: merged_message_text}]
    end

    recent_messages ++ [%{role: "user", content: current_content}]
  end

  defp call_claude(messages, system_prompt, user_id, enabled_tools, chat_id) do
    api_key = System.get_env("ANTHROPIC_API_KEY") || System.get_env("CLAUDE_API_KEY")
    Logger.info("[GroupAgent] API key configured: #{if api_key, do: "yes (#{String.length(api_key)} chars)", else: "NO - MISSING"}")

    unless api_key do
      {:error, "ANTHROPIC_API_KEY not configured"}
    else
      enabled_tool_definitions =
        @tools
        |> Enum.filter(&(&1.name in enabled_tools))

      call_claude_with_tools(
        messages,
        system_prompt,
        api_key,
        0,
        user_id,
        enabled_tools,
        enabled_tool_definitions,
        chat_id
      )
    end
  end

  defp call_claude_with_tools(
         messages,
         system_prompt,
         api_key,
         depth,
         user_id,
         enabled_tools,
         enabled_tool_definitions,
         chat_id
       ) do
    if depth > 3 do
      {:error, "Max tool depth reached"}
    else
      body = Jason.encode!(%{
        model: @claude_model,
        max_tokens: 4096,
        system: system_prompt,
        tools: enabled_tool_definitions,
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
            {:ok, %{"content" => content, "stop_reason" => stop_reason} = parsed} ->
              Logger.info("[GroupAgent] Claude response received, stop_reason=#{inspect(stop_reason)}")

              if stop_reason == "tool_use" do
                # Handle tool calls
                handle_tool_response(
                  content,
                  messages,
                  system_prompt,
                  api_key,
                  depth,
                  user_id,
                  enabled_tools,
                  enabled_tool_definitions,
                  chat_id
                )
              else
                # Extract text from response
                text = extract_text(content)
                {:ok, text}
              end

            {:ok, %{"content" => content} = parsed} ->
              Logger.info("[GroupAgent] Claude response received, stop_reason=#{inspect(Map.get(parsed, "stop_reason"))}")
              # Extract text from response
              text = extract_text(content)
              {:ok, text}

            other ->
              Logger.error("[GroupAgent] Failed to parse Claude response: #{inspect(other)}")
              {:error, "Failed to parse Claude response"}
          end

        {:ok, %{status: status, body: body}} ->
          Logger.error("[GroupAgent] Claude API error: status=#{status} body=#{String.slice(body, 0..500)}")
          {:error, "API error: #{status}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp handle_tool_response(
         content,
         messages,
         system_prompt,
         api_key,
         depth,
         user_id,
         enabled_tools,
         enabled_tool_definitions,
         chat_id
       ) do
    # Extract tool calls from content
    tool_calls = Enum.filter(content, fn
      %{"type" => "tool_use"} -> true
      _ -> false
    end)

    # Execute tools
    tool_results = Enum.map(tool_calls, fn tool ->
      result = execute_tool(tool["name"], tool["input"], user_id, enabled_tools, chat_id)
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

    call_claude_with_tools(
      new_messages,
      system_prompt,
      api_key,
      depth + 1,
      user_id,
      enabled_tools,
      enabled_tool_definitions,
      chat_id
    )
  end

  defp execute_tool(name, input, user_id, enabled_tools, chat_id) do
    if name in enabled_tools do
      start_time = System.monotonic_time(:millisecond)

      result =
        case name do
          "search_google" -> Vibe.AI.Tools.Search.google(input)
          "analyze_image" -> Vibe.AI.Tools.Vision.analyze(input)
          "analyze_document" -> Vibe.AI.Tools.Document.analyze(input)
          "create_document" -> create_document_tool(chat_id, input, user_id)
          _ -> %{error: "Unknown tool: #{name}"}
        end

      duration_ms = System.monotonic_time(:millisecond) - start_time
      Logger.info("[GroupAgent] Tool #{name} completed in #{duration_ms}ms")
      result
    else
      Logger.warning("[GroupAgent] Blocked disabled tool call #{name}")
      %{error: "Tool '#{name}' is disabled for this group."}
    end
  end

  defp create_document_tool(chat_id, input, user_id) do
    title =
      input
      |> tool_input_value("title")
      |> default_if_blank("Document")

    body =
      input
      |> tool_input_value("body")
      |> default_if_blank("Draft content")

    format =
      input
      |> tool_input_value("format")
      |> normalize_document_format()

    sections =
      case input do
        %{"sections" => raw_sections} -> normalize_section_headings(raw_sections)
        %{sections: raw_sections} -> normalize_section_headings(raw_sections)
        _ -> []
      end

    structured_body =
      if sections == [] do
        body
      else
        headings =
          sections
          |> Enum.map_join("\n", fn heading -> "## #{heading}\n\n- Add details here." end)

        body <> "\n\n" <> headings
      end

    case format do
      "csv" ->
        build_spreadsheet_document(chat_id, input, title, body, sections, user_id)

      _ ->
        content =
          case format do
            "plain_text" ->
              "#{title}\n\n#{structured_body}"

            "html" ->
              "<h1>#{escape_html(title)}</h1>\n<p>#{escape_html(structured_body)}</p>"

            "json" ->
              Jason.encode!(%{
                title: title,
                content: structured_body,
                sections: sections
              })

            _ ->
              "# #{title}\n\n#{structured_body}"
          end

        %{
          ok: true,
          title: title,
          format: format,
          content: content,
          note: "Document draft generated. You can send or refine it in chat."
        }
    end
  end

  defp build_spreadsheet_document(chat_id, input, title, body, sections, user_id) do
    current_document = GroupAgentDocument.get_current(chat_id)
    operation = resolve_spreadsheet_operation(input, current_document)

    case operation do
      :create_new ->
        create_new_spreadsheet_document(chat_id, input, title, body, sections, user_id)

      :append_rows ->
        edit_current_spreadsheet_document(
          chat_id,
          input,
          title,
          body,
          sections,
          user_id,
          current_document,
          :append_rows
        )

      :replace_rows ->
        edit_current_spreadsheet_document(
          chat_id,
          input,
          title,
          body,
          sections,
          user_id,
          current_document,
          :replace_rows
        )

      :revert_last ->
        revert_spreadsheet_document(chat_id, title, body, user_id, current_document)

      :edit_current ->
        edit_current_spreadsheet_document(
          chat_id,
          input,
          title,
          body,
          sections,
          user_id,
          current_document,
          :edit_current
        )
    end
  end

  defp normalize_document_format(raw_format) do
    raw_format
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "plain_text" -> "plain_text"
      "text" -> "plain_text"
      "html" -> "html"
      "json" -> "json"
      "csv" -> "csv"
      "xlsx" -> "csv"
      "excel" -> "csv"
      "spreadsheet" -> "csv"
      "google_sheet" -> "csv"
      "google_sheets" -> "csv"
      _ -> "markdown"
    end
  end

  defp resolve_spreadsheet_operation(input, current_document) do
    raw_operation =
      input
      |> tool_input_value("operation")
      |> String.downcase()

    hint_text =
      [
        tool_input_value(input, "body"),
        tool_input_value(input, "title")
      ]
      |> Enum.join(" ")
      |> String.downcase()

    case raw_operation do
      op when op in ["create_new", "new"] ->
        if current_document && not explicit_new_request_in_input?(input) do
          :edit_current
        else
          :create_new
        end

      "append_rows" -> :append_rows
      "append" -> :append_rows
      "replace_rows" -> :replace_rows
      "edit_current" -> :edit_current
      "edit" -> :edit_current
      "update" -> :edit_current
      "revert_last" -> :revert_last
      "undo" -> :revert_last
      "rollback" -> :revert_last
      _ ->
        cond do
          undo_intent?(hint_text) ->
            :revert_last

          current_document && new_file_request?(hint_text) ->
            :create_new

          current_document && append_request?(hint_text) ->
            :append_rows

          current_document ->
            :edit_current

          true ->
            :create_new
        end
    end
  end

  defp explicit_new_request_in_input?(input) do
    hint =
      [
        tool_input_value(input, "body"),
        tool_input_value(input, "title")
      ]
      |> Enum.join(" ")
      |> String.downcase()

    new_file_request?(hint)
  end

  defp create_new_spreadsheet_document(chat_id, input, title, body, sections, user_id) do
    columns = spreadsheet_columns(input, sections, [])
    rows = spreadsheet_rows(input, columns, body, [])
    csv_content = csv_from_rows(columns, rows)

    with {:ok, %{relative_url: relative_url, file_url: file_url}} <-
           write_agent_document_file(title, csv_content, "csv"),
         {:ok, doc} <-
           persist_document_version(
             chat_id,
             title,
             "csv",
             relative_url,
             file_url,
             columns,
             length(rows),
             build_spreadsheet_metadata("create_new", nil, body),
             "create",
             user_id
           ) do
      spreadsheet_tool_response(
        doc,
        columns,
        rows,
        csv_content,
        "Spreadsheet created. Future edits in this group update this file unless user asks for a new one."
      )
    else
      {:error, reason} ->
        Logger.error("[GroupAgent] Failed to create spreadsheet: #{inspect(reason)}")
        spreadsheet_error_response(title, reason)
    end
  end

  defp edit_current_spreadsheet_document(
         chat_id,
         input,
         title,
         body,
         sections,
         user_id,
         current_document,
         operation
       ) do
    if is_nil(current_document) do
      create_new_spreadsheet_document(chat_id, input, title, body, sections, user_id)
    else
      with {:ok, existing_csv} <- read_agent_document_file(current_document.relative_url) do
        {existing_columns, existing_rows} = parse_csv_content(existing_csv)
        columns = spreadsheet_columns(input, sections, existing_columns)
        existing_rows_aligned = align_rows_to_column_count(existing_rows, length(columns))

        explicit_rows =
          input
          |> tool_input_raw("rows")
          |> normalize_spreadsheet_rows(columns)

        inferred_rows =
          maybe_infer_rows_from_body(body, columns, operation, explicit_rows)

        incoming_rows = if explicit_rows == [], do: inferred_rows, else: explicit_rows

        final_rows =
          case operation do
            :append_rows ->
              existing_rows_aligned ++ incoming_rows

            :replace_rows ->
              if incoming_rows == [], do: existing_rows_aligned, else: incoming_rows

            :edit_current ->
              if incoming_rows == [], do: existing_rows_aligned, else: incoming_rows
          end
          |> ensure_non_empty_rows(columns, body)

        csv_content = csv_from_rows(columns, final_rows)

        with {:ok, %{relative_url: relative_url, file_url: file_url}} <-
               write_agent_document_file(title, csv_content, "csv"),
             {:ok, doc} <-
               persist_document_version(
                 chat_id,
                 title,
                 "csv",
                 relative_url,
                 file_url,
                 columns,
                 length(final_rows),
                 build_spreadsheet_metadata(to_string(operation), current_document.version, body),
                 "edit",
                 user_id
               ) do
          spreadsheet_tool_response(
            doc,
            columns,
            final_rows,
            csv_content,
            "Spreadsheet updated from current group context (version #{current_document.version} -> #{doc.version})."
          )
        else
          {:error, reason} ->
            Logger.error("[GroupAgent] Failed to edit spreadsheet: #{inspect(reason)}")
            spreadsheet_error_response(title, reason)
        end
      else
        {:error, reason} ->
          Logger.error("[GroupAgent] Failed to read current spreadsheet: #{inspect(reason)}")
          spreadsheet_error_response(title, reason)
      end
    end
  end

  defp revert_spreadsheet_document(chat_id, title, body, user_id, current_document) do
    if is_nil(current_document) do
      %{
        ok: false,
        format: "csv",
        title: title,
        error: "No active spreadsheet to revert in this group."
      }
    else
      previous_document = find_previous_document(chat_id, current_document)

      if is_nil(previous_document) do
        %{
          ok: false,
          format: "csv",
          title: title,
          error: "No previous spreadsheet version available to revert."
        }
      else
        with {:ok, csv_content} <- read_agent_document_file(previous_document.relative_url),
             {columns, rows} <- parse_csv_content(csv_content),
             {:ok, %{relative_url: relative_url, file_url: file_url}} <-
               write_agent_document_file(previous_document.title, csv_content, "csv"),
             {:ok, doc} <-
               persist_document_version(
                 chat_id,
                 previous_document.title,
                 "csv",
                 relative_url,
                 file_url,
                 columns,
                 length(rows),
                 build_spreadsheet_metadata("revert_last", current_document.version, body),
                 "revert",
                 user_id
               ) do
          spreadsheet_tool_response(
            doc,
            columns,
            rows,
            csv_content,
            "Reverted spreadsheet to previous content safely. A new version snapshot was created."
          )
        else
          {:error, reason} ->
            Logger.error("[GroupAgent] Failed to revert spreadsheet: #{inspect(reason)}")
            spreadsheet_error_response(title, reason)
        end
      end
    end
  end

  defp find_previous_document(chat_id, %GroupAgentDocument{} = current_document) do
    case current_document.previous_document_id do
      prev_id when is_binary(prev_id) ->
        case GroupAgentDocument.get_by_id(prev_id) do
          %GroupAgentDocument{chat_id: ^chat_id} = previous -> previous
          _ -> GroupAgentDocument.get_previous(chat_id, current_document.version)
        end

      _ ->
        GroupAgentDocument.get_previous(chat_id, current_document.version)
    end
  end

  defp persist_document_version(
         chat_id,
         title,
         format,
         relative_url,
         file_url,
         columns,
         row_count,
         metadata,
         change_type,
         user_id
       ) do
    GroupAgentDocument.create_new_version(chat_id, %{
      title: default_if_blank(title, "Spreadsheet"),
      format: default_if_blank(format, "csv"),
      relative_url: relative_url,
      file_url: file_url,
      columns: normalize_string_list(columns),
      row_count: max(row_count || 0, 0),
      metadata: if(is_map(metadata), do: metadata, else: %{}),
      change_type: change_type,
      created_by_user_id: user_id
    })
  end

  defp spreadsheet_tool_response(doc, columns, rows, csv_content, note) do
    %{
      ok: true,
      title: doc.title,
      format: "csv",
      columns: columns,
      rows: rows,
      row_count: length(rows),
      content: csv_content,
      download_path: doc.relative_url,
      file_url: doc.file_url,
      version: doc.version,
      change_type: doc.change_type,
      note: note
    }
  end

  defp spreadsheet_error_response(title, reason) do
    %{
      ok: false,
      error: "Failed to handle spreadsheet file",
      reason: inspect(reason),
      format: "csv",
      title: title
    }
  end

  defp build_spreadsheet_metadata(operation, source_version, body) do
    %{
      "operation" => operation,
      "source_version" => source_version,
      "request_hint" => body |> to_string() |> String.slice(0, 300)
    }
  end

  defp spreadsheet_columns(input, sections, fallback_columns \\ []) do
    columns =
      input
      |> tool_input_raw("columns")
      |> normalize_string_list()

    cond do
      columns != [] ->
        columns

      sections != [] ->
        sections

      fallback_columns != [] ->
        fallback_columns

      true ->
        ["Item", "Value"]
    end
  end

  defp spreadsheet_rows(input, columns, body, fallback_rows \\ []) do
    normalized_rows =
      input
      |> tool_input_raw("rows")
      |> normalize_spreadsheet_rows(columns)

    cond do
      normalized_rows != [] ->
        normalized_rows

      fallback_rows != [] ->
        align_rows_to_column_count(fallback_rows, length(columns))

      true ->
        [default_spreadsheet_row(columns, body)]
    end
  end

  defp normalize_spreadsheet_rows(raw_rows, columns) when is_list(raw_rows) do
    raw_rows
    |> Enum.map(&normalize_single_spreadsheet_row(&1, columns))
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_spreadsheet_rows(_, _), do: []

  defp normalize_single_spreadsheet_row(raw_row, columns) when is_list(raw_row) do
    raw_row
    |> Enum.map(&to_string(&1 || ""))
    |> fit_row_to_column_count(length(columns))
  end

  defp normalize_single_spreadsheet_row(raw_row, columns) when is_map(raw_row) do
    normalized_lookup =
      raw_row
      |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), to_string(v || "")} end)
      |> Map.new()

    columns
    |> Enum.map(fn col -> Map.get(normalized_lookup, String.downcase(col), "") end)
    |> fit_row_to_column_count(length(columns))
  end

  defp normalize_single_spreadsheet_row(raw_row, columns) when is_binary(raw_row) do
    raw_row
    |> String.split(~r/\s*,\s*/, trim: true)
    |> fit_row_to_column_count(length(columns))
  end

  defp normalize_single_spreadsheet_row(_, _), do: nil

  defp fit_row_to_column_count(values, column_count) when is_list(values) and column_count >= 0 do
    trimmed =
      values
      |> Enum.map(&to_string(&1 || ""))
      |> Enum.take(column_count)

    padding_count = max(column_count - length(trimmed), 0)
    trimmed ++ List.duplicate("", padding_count)
  end

  defp align_rows_to_column_count(rows, column_count) when is_list(rows) do
    Enum.map(rows, &fit_row_to_column_count(&1, column_count))
  end

  defp align_rows_to_column_count(_, _), do: []

  defp ensure_non_empty_rows(rows, columns, body) do
    if rows == [] do
      [default_spreadsheet_row(columns, body)]
    else
      rows
    end
  end

  defp default_spreadsheet_row(columns, body) do
    first_cell =
      body
      |> to_string()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> default_if_blank("Sample row")
      |> String.slice(0, 120)

    [first_cell]
    |> fit_row_to_column_count(length(columns))
  end

  defp maybe_infer_rows_from_body(body, columns, operation, existing_rows) do
    if existing_rows == [] and operation == :append_rows and body_has_data_hint?(body) do
      [default_spreadsheet_row(columns, body)]
    else
      []
    end
  end

  defp body_has_data_hint?(body) do
    text = body |> to_string() |> String.trim() |> String.downcase()
    text != "" and text != "draft content" and text != "document"
  end

  defp read_agent_document_file(relative_url) do
    with {:ok, full_path} <- resolve_agent_document_path(relative_url),
         {:ok, content} <- File.read(full_path) do
      {:ok, content}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp resolve_agent_document_path(relative_url) do
    normalized = relative_url |> to_string() |> String.trim()

    relative_path =
      cond do
        String.starts_with?(normalized, "/uploads/#{@agent_docs_dir}/") ->
          String.trim_leading(normalized, "/uploads/")

        String.starts_with?(normalized, "#{@agent_docs_dir}/") ->
          normalized

        true ->
          nil
      end

    if is_nil(relative_path) or relative_path == "" or String.contains?(relative_path, "..") do
      {:error, :invalid_document_path}
    else
      full_path = Path.expand(Path.join(@uploads_dir, relative_path))
      uploads_root = Path.expand(@uploads_dir)

      if String.starts_with?(full_path, uploads_root <> "/") do
        {:ok, full_path}
      else
        {:error, :invalid_document_path}
      end
    end
  end

  defp parse_csv_content(content) do
    rows =
      content
      |> to_string()
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.map(&parse_csv_line/1)
      |> Enum.reject(&(&1 == []))

    case rows do
      [] ->
        {["Item", "Value"], []}

      [header | body_rows] ->
        columns =
          header
          |> sanitize_csv_columns()

        {columns, align_rows_to_column_count(body_rows, length(columns))}
    end
  end

  defp sanitize_csv_columns(columns) when is_list(columns) do
    normalized =
      columns
      |> Enum.with_index(1)
      |> Enum.map(fn {column, idx} ->
        column
        |> to_string()
        |> String.trim()
        |> default_if_blank("Column #{idx}")
      end)

    if normalized == [], do: ["Item", "Value"], else: normalized
  end

  defp parse_csv_line(line) when is_binary(line) do
    line
    |> do_parse_csv_line([], "", false)
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
  end

  defp parse_csv_line(_), do: []

  defp do_parse_csv_line(<<>>, cells, cell, _in_quotes), do: [cell | cells]

  defp do_parse_csv_line(<<?", ?", rest::binary>>, cells, cell, true) do
    do_parse_csv_line(rest, cells, cell <> "\"", true)
  end

  defp do_parse_csv_line(<<?", rest::binary>>, cells, cell, true) do
    do_parse_csv_line(rest, cells, cell, false)
  end

  defp do_parse_csv_line(<<?", rest::binary>>, cells, cell, false) do
    do_parse_csv_line(rest, cells, cell, true)
  end

  defp do_parse_csv_line(<<?,, rest::binary>>, cells, cell, false) do
    do_parse_csv_line(rest, [cell | cells], "", false)
  end

  defp do_parse_csv_line(<<?\r, rest::binary>>, cells, cell, in_quotes) do
    do_parse_csv_line(rest, cells, cell, in_quotes)
  end

  defp do_parse_csv_line(<<char::utf8, rest::binary>>, cells, cell, in_quotes) do
    do_parse_csv_line(rest, cells, cell <> <<char::utf8>>, in_quotes)
  end

  defp csv_from_rows(columns, rows) do
    lines = [
      Enum.map_join(columns, ",", &csv_escape_cell/1)
      | Enum.map(rows, fn row -> Enum.map_join(row, ",", &csv_escape_cell/1) end)
    ]

    Enum.join(lines, "\n") <> "\n"
  end

  defp csv_escape_cell(value) do
    text =
      value
      |> to_string()
      |> String.replace(~r/\r\n?|\n/, " ")

    escaped = String.replace(text, "\"", "\"\"")

    if String.contains?(escaped, ",") or String.contains?(escaped, "\"") or
         String.contains?(escaped, "\n") or String.contains?(escaped, "\r") do
      "\"#{escaped}\""
    else
      escaped
    end
  end

  defp write_agent_document_file(title, content, extension) do
    docs_dir = Path.join(@uploads_dir, @agent_docs_dir)
    filename = build_agent_document_filename(title, extension)
    full_path = Path.join(docs_dir, filename)
    relative_url = "/uploads/#{@agent_docs_dir}/#{filename}"

    with :ok <- File.mkdir_p(docs_dir),
         :ok <- File.write(full_path, content) do
      {:ok,
       %{
         relative_url: relative_url,
         file_url: public_upload_url(relative_url)
       }}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_agent_document_filename(title, extension) do
    ts = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    slug = sanitize_filename_token(title)
    "#{ts}-#{slug}-#{suffix}.#{extension}"
  end

  defp sanitize_filename_token(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> default_if_blank("document")
    |> String.slice(0, 60)
  end

  defp public_upload_url(relative_url) do
    base_url =
      System.get_env("PUBLIC_BASE_URL") ||
        System.get_env("API_BASE_URL") ||
        endpoint_url()

    if is_binary(base_url) and String.trim(base_url) != "" do
      String.trim_trailing(base_url, "/") <> relative_url
    else
      relative_url
    end
  end

  defp endpoint_url do
    try do
      VibeWeb.Endpoint.url()
    rescue
      _ -> ""
    end
  end

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_string_list(value) when is_binary(value) do
    value
    |> String.split(~r/[\n,|]/, trim: true)
    |> normalize_string_list()
  end

  defp normalize_string_list(_), do: []

  defp tool_input_raw(input, key) do
    case input do
      %{^key => value} ->
        value

      %{} ->
        try do
          Map.get(input, String.to_existing_atom(key))
        rescue
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp tool_input_value(input, key) do
    case input do
      %{^key => value} -> to_string(value || "")
      %{} ->
        atom_value =
          try do
            Map.get(input, String.to_existing_atom(key), "")
          rescue
            _ -> ""
          end

        to_string(atom_value || "")
      _ -> ""
    end
    |> String.trim()
  end

  defp normalize_section_headings(raw_sections) when is_list(raw_sections) do
    raw_sections
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_section_headings(_), do: []

  defp escape_html(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp default_if_blank(text, fallback) do
    trimmed = text |> to_string() |> String.trim()
    if trimmed == "", do: fallback, else: trimmed
  end

  defp maybe_attach_spreadsheet_fallback(chat_id, user_message, response, enabled_tools, user_id) do
    if should_auto_generate_spreadsheet?(chat_id, user_message, response, enabled_tools) do
      title = infer_spreadsheet_title(user_message)
      operation = infer_fallback_spreadsheet_operation(user_message, chat_id)

      case create_document_tool(chat_id, %{
             "title" => title,
             "body" => user_message,
             "format" => "csv",
             "operation" => operation
           }, user_id) do
        %{ok: true, file_url: file_url, row_count: row_count} = result ->
          Logger.info(
            "[GroupAgent] Auto-generated spreadsheet fallback title=#{title} rows=#{row_count} operation=#{operation}"
          )

          fallback_message = spreadsheet_fallback_message(file_url, row_count, result[:columns] || [])

          if refusal_language?(response) do
            fallback_message
          else
            response <> "\n\n" <> fallback_message
          end

        _ ->
          response
      end
    else
      response
    end
  end

  defp should_auto_generate_spreadsheet?(chat_id, user_message, response, enabled_tools) do
    has_current = not is_nil(GroupAgentDocument.get_current(chat_id))
    trigger = spreadsheet_intent?(user_message) or (has_current and undo_intent?(user_message))

    "create_document" in enabled_tools and trigger and not response_contains_download_link?(response)
  end

  defp undo_intent?(message) do
    down = message |> to_string() |> String.downcase()
    String.contains?(down, "undo") or String.contains?(down, "revert")
  end

  defp infer_fallback_spreadsheet_operation(user_message, chat_id) do
    message = user_message |> to_string() |> String.downcase()
    has_current = not is_nil(GroupAgentDocument.get_current(chat_id))

    cond do
      String.contains?(message, "revert") or String.contains?(message, "undo") ->
        "revert_last"

      has_current and new_file_request?(message) ->
        "create_new"

      has_current and append_request?(message) ->
        "append_rows"

      has_current ->
        "edit_current"

      true ->
        "create_new"
    end
  end

  defp new_file_request?(message) do
    Enum.any?(
      [
        "new file",
        "new sheet",
        "new spreadsheet",
        "from scratch",
        "start over",
        "another file"
      ],
      &String.contains?(message, &1)
    )
  end

  defp append_request?(message) do
    Enum.any?(
      ["add row", "append", "add this row", "insert row", "add rows"],
      &String.contains?(message, &1)
    )
  end

  defp spreadsheet_intent?(message) do
    down = message |> to_string() |> String.downcase()

    spreadsheet_terms = [
      "excel",
      "xlsx",
      "spreadsheet",
      "google sheet",
      "google sheets",
      "csv",
      "rows",
      "columns"
    ]

    action_terms = [
      "create",
      "make",
      "generate",
      "build",
      "export",
      "prepare",
      "edit",
      "update",
      "add",
      "append",
      "revert",
      "undo"
    ]

    Enum.any?(spreadsheet_terms, &String.contains?(down, &1)) and
      Enum.any?(action_terms, &String.contains?(down, &1))
  end

  defp response_contains_download_link?(response) do
    text = response |> to_string() |> String.downcase()

    String.contains?(text, "/uploads/") or
      Regex.match?(~r/https?:\/\/\S+\.(csv|xlsx?)(\?\S*)?/i, text) or
      Regex.match?(~r/https?:\/\/\S+\/agent-docs\/\S+/i, text)
  end

  defp refusal_language?(response) do
    down = response |> to_string() |> String.downcase()

    refusal_markers = [
      "i can't",
      "i cannot",
      "not able",
      "unable to",
      "can't directly",
      "cannot directly"
    ]

    Enum.any?(refusal_markers, &String.contains?(down, &1))
  end

  defp infer_spreadsheet_title(message) do
    summary =
      message
      |> to_string()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.slice(0, 40)

    "Spreadsheet - " <> default_if_blank(summary, "Data")
  end

  defp spreadsheet_fallback_message(_file_url, row_count, columns) do
    col_count = length(columns)

    "Created editable spreadsheet file (CSV) and attached it.\nColumns: #{col_count}, Rows: #{row_count}\nYou can open it in Excel or Google Sheets."
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

  defp normalize_tools_input(raw_tools) do
    cond do
      is_list(raw_tools) ->
        Enum.map(raw_tools, &to_string/1)

      is_binary(raw_tools) ->
        raw_tools
        |> String.split(",")
        |> Enum.map(&String.trim/1)

      true ->
        []
    end
  end

  defp build_prompt_generation_instruction(user_input, enabled_tools) do
    tool_list =
      enabled_tools
      |> Enum.map_join(", ", &"`#{&1}`")

    """
    Create a high-quality system prompt for a group chat AI assistant.
    The prompt must be practical, concise, and optimized for short mobile-chat answers.
    It should include tone, boundaries, response style, and how to use tools safely.
    Enabled tools for this assistant: #{tool_list}.

    Admin's high-level intent:
    #{user_input}

    Return only the final system prompt text. No markdown fences. No explanations.
    """
  end

  defp normalize_generated_prompt(raw_prompt, fallback_input) do
    generated =
      raw_prompt
      |> to_string()
      |> String.trim()
      |> String.trim_leading("\"")
      |> String.trim_trailing("\"")

    if String.length(generated) < 40 do
      fallback_generated_prompt(fallback_input)
    else
      generated
    end
  end

  defp fallback_generated_prompt(user_input) do
    """
    #{@default_system_prompt}

    Group-specific objective:
    #{user_input}

    Behavior:
    - Prioritize direct answers in 1-3 short paragraphs.
    - Ask clarifying questions when user intent is ambiguous.
    - Use enabled tools when they improve factual accuracy or attachment analysis.
    - If a requested action requires a disabled tool, state that clearly and suggest an alternative.
    """
    |> String.trim()
  end

  defp normalize_url_list(raw_urls) when is_list(raw_urls) do
    raw_urls
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_url_list(raw_urls) when is_binary(raw_urls) do
    normalize_url_list([raw_urls])
  end

  defp normalize_url_list(_), do: []

  defp build_attachment_context(image_urls, document_urls) do
    image_lines = Enum.map(image_urls, &"- image: #{&1}")
    document_lines = Enum.map(document_urls, &"- document: #{&1}")
    lines = image_lines ++ document_lines
    if lines == [], do: "", else: "Attached context:\n" <> Enum.join(lines, "\n")
  end

  defp append_attachment_context(current_message, attachment_context) do
    base = current_message |> to_string() |> String.trim()

    if attachment_context == "" do
      base
    else
      [base, attachment_context]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
    end
  end

  defp summarize_attachments_for_memory(metadata) do
    images = normalize_url_list(Map.get(metadata, "image_urls", []))
    documents = normalize_url_list(Map.get(metadata, "document_urls", []))
    %{images: images, documents: documents}
  end

  defp append_attachment_summary_for_storage(content, %{images: images, documents: documents}) do
    summary_lines =
      (Enum.map(images, &"[image] #{&1}") ++ Enum.map(documents, &"[document] #{&1}"))
      |> Enum.uniq()

    if summary_lines == [] do
      content
    else
      [content, Enum.join(summary_lines, "\n")]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end
  end

  defp broadcast_agent_message(chat_id, agent_config, text, metadata) do
    Logger.info("[GroupAgent] Broadcasting agent message in #{chat_id}: #{String.slice(text, 0..80)}...")

    message_id = Ecto.UUID.generate()
    timestamp = :os.system_time(:millisecond)
    reply_to_id = Map.get(metadata, "reply_to_id")
    attachment = extract_agent_document_attachment(chat_id, text)
    plain_text = sanitize_agent_plain_text(text, attachment)
    message_type = if attachment, do: "file", else: "text"

    payload_base = %{
      "id" => message_id,
      "fromId" => @agent_user_id,
      "chatId" => chat_id,
      "encryptedContent" => "",
      "plainContent" => plain_text,
      "type" => message_type,
      "timestamp" => timestamp,
      "status" => "sent",
      "isAgentMessage" => true,
      "agentName" => agent_config.name,
      "replyToId" => reply_to_id
    }

    payload =
      case attachment do
        %{url: url, file_name: file_name} ->
          payload_base
          |> Map.put("mediaUrl", url)
          |> Map.put("fileName", file_name)

        _ ->
          payload_base
      end

    # Broadcast to the chat channel
    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "message", payload)

    # Persist the agent message to the database
    Task.start(fn ->
      case ensure_agent_user_record() do
        :ok ->
          message_attrs_base = %{
            id: message_id,
            chat_id: chat_id,
            from_id: @agent_user_id,
            encrypted_content: plain_text,
            type: message_type,
            timestamp: timestamp,
            reply_to_id: reply_to_id
          }

          message_attrs =
            case attachment do
              %{url: url} -> Map.put(message_attrs_base, :media_url, url)
              _ -> message_attrs_base
            end

          case Vibe.Chat.add_message(message_attrs) do
            {:ok, _msg} ->
              Logger.info(
                "[GroupAgent] Agent message persisted chat_id=#{chat_id} message_id=#{message_id}"
              )

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

        {:error, reason} ->
          Logger.error("[GroupAgent] Failed to ensure agent user row: #{inspect(reason)}")
      end
    end)
  end

  defp ensure_agent_user_record do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    agent_user_id = Ecto.UUID.dump!(@agent_user_id)

    Repo.insert_all(
      "users",
      [
        %{
          id: agent_user_id,
          username: @agent_username,
          password_hash: "agent",
          public_key: "agent",
          device_id: "agent",
          inserted_at: now,
          updated_at: now
        }
      ],
      conflict_target: [:id],
      on_conflict: [set: [updated_at: now]]
    )

    :ok
  rescue
    error -> {:error, error}
  end

  defp extract_agent_document_attachment(chat_id, text) do
    with {:ok, url} <- extract_agent_document_url(text, chat_id),
         file_name <- derive_file_name_from_url(url),
         true <- not is_nil(file_name) do
      %{url: url, file_name: file_name}
    else
      _ -> nil
    end
  end

  defp extract_agent_document_url(text, chat_id) do
    normalized_text = text |> to_string()

    absolute =
      Regex.scan(~r/https?:\/\/[^\s)]+/i, normalized_text)
      |> List.flatten()
      |> Enum.find(&String.contains?(&1, "/uploads/#{@agent_docs_dir}/"))

    relative =
      Regex.scan(~r/\/uploads\/agent-docs\/[^\s)]+/i, normalized_text)
      |> List.flatten()
      |> List.first()

    cond do
      is_binary(absolute) and absolute != "" ->
        {:ok, absolute}

      is_binary(relative) and relative != "" ->
        {:ok, public_upload_url(relative)}

      true ->
        if document_intent_in_response?(normalized_text) do
          case GroupAgentDocument.get_current(chat_id) do
            %GroupAgentDocument{file_url: file_url} when is_binary(file_url) and file_url != "" ->
              {:ok, file_url}

            _ ->
              {:error, :not_found}
          end
        else
          {:error, :not_found}
        end
    end
  end

  defp derive_file_name_from_url(url) when is_binary(url) do
    url
    |> String.split("?")
    |> List.first()
    |> to_string()
    |> Path.basename()
    |> case do
      "" -> nil
      name -> name
    end
  end

  defp derive_file_name_from_url(_), do: nil

  defp sanitize_agent_plain_text(text, attachment) do
    normalized = text |> to_string()

    stripped =
      normalized
      |> strip_upload_links()
      |> maybe_strip_remaining_links(attachment)
      |> String.replace(~r/\n{3,}/, "\n\n")
      |> String.trim()

    cond do
      stripped != "" ->
        stripped

      attachment && is_map(attachment) ->
        "Document attached."

      true ->
        "Agent response"
    end
  end

  defp strip_upload_links(text) do
    text
    |> String.replace(~r/https?:\/\/[^\s)]*\/uploads\/agent-docs\/[^\s)]+/i, "")
    |> String.replace(~r/\/uploads\/agent-docs\/[^\s)]+/i, "")
    |> String.replace(~r/\[([^\]]+)\]\(\s*\)/, "\\1")
    |> String.trim()
  end

  defp maybe_strip_remaining_links(text, attachment) when is_map(attachment) do
    text
    |> String.replace(~r/https?:\/\/[^\s)]+/i, "")
    |> String.replace(~r/\[([^\]]+)\]\(\s*\)/, "\\1")
    |> String.trim()
  end

  defp maybe_strip_remaining_links(text, _attachment), do: text

  defp document_intent_in_response?(text) do
    down = text |> to_string() |> String.downcase()

    Enum.any?(
      ["spreadsheet", "excel", "csv", "document", "file", "attached", "download"],
      &String.contains?(down, &1)
    )
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
