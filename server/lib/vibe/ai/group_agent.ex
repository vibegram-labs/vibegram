defmodule Vibe.AI.GroupAgent do
  @moduledoc """
  AI Agent for group/channel chats.
  Handles @vibe mentions, generates responses with per-group custom prompts,
  and manages conversation memory with auto-compaction.
  """

  require Logger

  alias Vibe.Chat.{GroupAgent, GroupAgentMemory, GroupAgentDocument, AgentMessageCrypto}
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
  @max_agent_document_bytes 1_000_000

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
        "Create or edit a formatted document OR editable spreadsheet file scoped to this group. For spreadsheet requests, default to format xlsx (Excel) unless user explicitly asks for csv.",
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
            description: "Output document format. Use xlsx/excel/spreadsheet/google_sheet by default for editable table files; use csv only when explicitly requested."
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

    case GroupAgent.get_enabled_by_chat(chat_id, acting_user_id: user_id) do
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
    {:ok, memory} = GroupAgentMemory.get_or_create(chat_id, acting_user_id: user_id)
    Logger.info("[GroupAgent] Memory loaded for #{chat_id}: #{length(memory.messages)} messages, summary=#{if memory.summary, do: "yes", else: "no"}")

    # 2. Build system prompt with memory + current group document context
    group_document_context = build_group_document_context(chat_id)
    system_prompt = build_system_prompt(agent_config, memory, enabled_tools, group_document_context)

    # 3. Build message history from memory + current message
    messages = build_messages(memory, user_message, metadata)
    Logger.info("[GroupAgent] Calling Claude for #{chat_id}: #{length(messages)} messages, system_prompt_len=#{String.length(system_prompt)}")

    # 4. Call Claude
    case call_claude(messages, system_prompt, user_id, enabled_tools, chat_id) do
      {:ok, %{text: response_text, attachment: tool_attachment}} ->
        fallback_result =
          maybe_attach_spreadsheet_fallback(
            chat_id,
            user_message,
            response_text,
            enabled_tools,
            user_id,
            tool_attachment
          )

        response = fallback_result.text
        resolved_attachment = fallback_result.attachment

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
        }, acting_user_id: user_id)

        GroupAgentMemory.append_message(chat_id, %{
          "role" => "assistant",
          "content" => response
        }, acting_user_id: user_id)

        # 6. Check if compaction needed
        maybe_compact(chat_id, user_id)

        # 7. Broadcast agent response as a chat message
        broadcast_agent_message(
          chat_id,
          agent_config,
          response,
          user_id,
          metadata,
          resolved_attachment
        )

        {:ok, response}

      {:error, reason} ->
        Logger.error("[GroupAgent] Claude error for chat #{chat_id}: #{inspect(reason)}")
        # Broadcast an error message so users know something went wrong
        broadcast_agent_message(
          chat_id,
          agent_config,
          "Sorry, I encountered an error processing your request. Please try again.",
          user_id,
          metadata
        )
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

    CONVERSATION:
    - You are #{agent_config.name}, an AI assistant in this group chat.
    - Keep responses concise and relevant — this is mobile chat.
    - ALWAYS reply in the same language the user wrote in. If they write in Persian, reply in Persian. If Arabic, reply in Arabic. Match their language exactly.
    - Address users naturally, referring to the group context.
    - You can reference previous conversations from your memory.
    - When using tools, call them IMMEDIATELY without intro text.
    - Only use tools that are enabled for this group.
    - If attachments are provided in the current message context, use them.

    DATA INTERPRETATION:
    - When a user describes data in natural language, carefully parse their intent and extract structured values.
    - Convert messy descriptions into clean, normalized cell values (e.g. "٣٠/٠٠٠ درهم" → "30,000").
    - Calculate totals, balances, and summaries yourself — do not copy the user's arithmetic verbatim.
    - If the user's request is ambiguous, ask a brief clarifying question before creating the document.

    DOCUMENT & SPREADSHEET:
    - For document/file requests, generate professional outputs with clean structure and naming.
    - When a tool creates/updates a file, respond naturally and state that the file is attached (do not paste raw URLs).
    - Never claim you cannot create/edit spreadsheet files when create_document is enabled.
    - The generated XLSX files already have styled headers (bold white on blue), borders, RTL layout, and fixed column widths — do NOT add formatting hints or decorators in cell text.
    - Spreadsheet behavior is stateful per group chat.
    - Default behavior is to edit the current spreadsheet for this chat.
    - Use operation=create_new only when user explicitly asks for a NEW file/from-scratch sheet.
    - For adding data, prefer operation=append_rows.
    - For corrections, prefer operation=edit_current or replace_rows.
    - If user asks to undo/revert, use operation=revert_last.
    - If user asks for Excel/sheet/spreadsheet/table with rows/columns, call create_document with format xlsx unless user explicitly asks for csv.
    - Spreadsheet quality:
      * Use clear, professional column headers in a stable order.
      * Keep every row aligned to the column count (no missing/extra cells).
      * Normalize noisy values (trim spaces, remove filler text, keep wording consistent).
      * Prefer normalized date and number representations (use digits, not words).
      * Each data item must appear exactly once — never duplicate rows.
      * Keep notes/comments in a dedicated column; never mix them into data value cells.
      * Separate summary or total rows clearly from data rows (place them last).
      * For RTL languages (Arabic, Persian/Farsi), order columns right-to-left and keep text concise per cell.

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
        chat_id,
        nil
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
         chat_id,
         pending_attachment
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
                  chat_id,
                  pending_attachment
                )
              else
                # Extract text from response
                text = extract_text(content)
                {:ok, %{text: text, attachment: pending_attachment}}
              end

            {:ok, %{"content" => content} = parsed} ->
              Logger.info("[GroupAgent] Claude response received, stop_reason=#{inspect(Map.get(parsed, "stop_reason"))}")
              # Extract text from response
              text = extract_text(content)
              {:ok, %{text: text, attachment: pending_attachment}}

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
         chat_id,
         pending_attachment
       ) do
    # Extract tool calls from content
    tool_calls = Enum.filter(content, fn
      %{"type" => "tool_use"} -> true
      _ -> false
    end)

    # Execute tools and carry forward latest attachment from create_document.
    {tool_results, latest_attachment} =
      Enum.reduce(tool_calls, {[], pending_attachment}, fn tool, {acc_results, acc_attachment} ->
        result = execute_tool(tool["name"], tool["input"], user_id, enabled_tools, chat_id)
        tool_attachment = extract_tool_attachment(tool["name"], result)

        tool_result = %{
          "type" => "tool_result",
          "tool_use_id" => tool["id"],
          "content" => Jason.encode!(result)
        }

        next_attachment = tool_attachment || acc_attachment
        {[tool_result | acc_results], next_attachment}
      end)

    tool_results = Enum.reverse(tool_results)

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
      chat_id,
      latest_attachment
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
        build_spreadsheet_document(chat_id, input, title, body, sections, user_id, "csv")

      "xlsx" ->
        build_spreadsheet_document(chat_id, input, title, body, sections, user_id, "xlsx")

      _ ->
        content =
          case format do
            "plain_text" ->
              "#{title}\n\n#{structured_body}"

            "html" ->
              build_html_document(title, structured_body)

            "json" ->
              Jason.encode!(%{
                title: title,
                content: structured_body,
                sections: sections
              })

            _ ->
              "# #{title}\n\n#{structured_body}"
          end

        extension = file_extension_for_document_format(format)

        with {:ok, storage} <- write_agent_document_file(title, content, extension),
             {:ok, doc} <-
               persist_document_version(
                 chat_id,
                 title,
                 format,
                 storage.relative_url,
                 storage.file_url,
                 [],
                 0,
                 merge_document_metadata(
                   build_document_metadata(format, body),
                   storage.metadata
                 ),
                 "create",
                 user_id
               ) do
          document_tool_response(
            doc,
            format,
            content,
            "Document created and attached."
          )
        else
          {:error, reason} ->
            Logger.error("[GroupAgent] Failed to create document format=#{format}: #{inspect(reason)}")
            document_error_response(title, format, reason)
        end
    end
  end

  defp build_spreadsheet_document(chat_id, input, title, body, sections, user_id, output_format) do
    current_document = GroupAgentDocument.get_current(chat_id)
    operation = resolve_spreadsheet_operation(input, current_document)
    resolved_output_format = resolve_spreadsheet_output_format(output_format, current_document)

    case operation do
      :create_new ->
        create_new_spreadsheet_document(
          chat_id,
          input,
          title,
          body,
          sections,
          user_id,
          resolved_output_format
        )

      :append_rows ->
        edit_current_spreadsheet_document(
          chat_id,
          input,
          title,
          body,
          sections,
          user_id,
          current_document,
          :append_rows,
          resolved_output_format
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
          :replace_rows,
          resolved_output_format
        )

      :revert_last ->
        revert_spreadsheet_document(
          chat_id,
          title,
          body,
          user_id,
          current_document,
          resolved_output_format
        )

      :edit_current ->
        edit_current_spreadsheet_document(
          chat_id,
          input,
          title,
          body,
          sections,
          user_id,
          current_document,
          :edit_current,
          resolved_output_format
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
      "xlsx" -> "xlsx"
      "excel" -> "xlsx"
      "spreadsheet" -> "xlsx"
      "google_sheet" -> "xlsx"
      "google_sheets" -> "xlsx"
      _ -> "markdown"
    end
  end

  defp resolve_spreadsheet_output_format(requested_format, current_document) do
    requested =
      requested_format
      |> to_string()
      |> String.trim()
      |> String.downcase()

    cond do
      requested == "csv" ->
        "csv"

      requested in ["xlsx", "excel", "spreadsheet", "google_sheet", "google_sheets"] ->
        "xlsx"

      is_struct(current_document, GroupAgentDocument) ->
        case current_document.format |> to_string() |> String.trim() |> String.downcase() do
          "csv" -> "csv"
          _ -> "xlsx"
        end

      true ->
        "xlsx"
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

  defp create_new_spreadsheet_document(
         chat_id,
         input,
         title,
         body,
         sections,
         user_id,
         output_format
       ) do
    columns = spreadsheet_columns(input, sections, [])
    rows = spreadsheet_rows(input, columns, body, [])

    with {:ok, storage, csv_content} <-
           write_spreadsheet_document_file(title, columns, rows, output_format),
         {:ok, doc} <-
           persist_document_version(
             chat_id,
             title,
             output_format,
             storage.relative_url,
             storage.file_url,
             columns,
             length(rows),
             merge_document_metadata(
               build_spreadsheet_metadata("create_new", nil, body),
               storage.metadata
             ),
             "create",
             user_id
      ) do
      spreadsheet_tool_response(
        doc,
        columns,
        rows,
        csv_content,
        "Spreadsheet created and attached. Future edits in this group update this file unless user asks for a new one."
      )
    else
      {:error, reason} ->
        Logger.error("[GroupAgent] Failed to create spreadsheet: #{inspect(reason)}")
        spreadsheet_error_response(title, reason, output_format)
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
         operation,
         output_format
       ) do
    if is_nil(current_document) do
      create_new_spreadsheet_document(
        chat_id,
        input,
        title,
        body,
        sections,
        user_id,
        output_format
      )
    else
      with {:ok, existing_csv} <- read_agent_document_file(current_document) do
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

        with {:ok, storage, csv_content} <-
               write_spreadsheet_document_file(title, columns, final_rows, output_format),
             {:ok, doc} <-
               persist_document_version(
                 chat_id,
                 title,
                 output_format,
                 storage.relative_url,
                 storage.file_url,
                 columns,
                 length(final_rows),
                 merge_document_metadata(
                   build_spreadsheet_metadata(to_string(operation), current_document.version, body),
                   storage.metadata
                 ),
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
            spreadsheet_error_response(title, reason, output_format)
        end
      else
        {:error, :enoent} ->
          Logger.warning(
            "[GroupAgent] Current spreadsheet source missing for chat #{chat_id}; rebuilding from current schema."
          )

          columns = spreadsheet_columns(input, sections, List.wrap(current_document.columns))

          incoming_rows =
            input
            |> tool_input_raw("rows")
            |> normalize_spreadsheet_rows(columns)

          final_rows = ensure_non_empty_rows(incoming_rows, columns, body)

          with {:ok, storage, csv_content} <-
                 write_spreadsheet_document_file(title, columns, final_rows, output_format),
               {:ok, doc} <-
                 persist_document_version(
                   chat_id,
                   title,
                   output_format,
                   storage.relative_url,
                   storage.file_url,
                   columns,
                   length(final_rows),
                   merge_document_metadata(
                     build_spreadsheet_metadata("rebuild_missing_source", current_document.version, body),
                     storage.metadata
                   ),
                   "edit",
                   user_id
                 ) do
            spreadsheet_tool_response(
              doc,
              columns,
              final_rows,
              csv_content,
              "Source file was missing; rebuilt and attached a fresh spreadsheet version."
            )
          else
            {:error, reason} ->
              Logger.error("[GroupAgent] Failed to rebuild missing spreadsheet: #{inspect(reason)}")
              spreadsheet_error_response(title, reason, output_format)
          end

        {:error, reason} ->
          Logger.error("[GroupAgent] Failed to read current spreadsheet: #{inspect(reason)}")
          spreadsheet_error_response(title, reason, output_format)
      end
    end
  end

  defp revert_spreadsheet_document(
         chat_id,
         title,
         body,
         user_id,
         current_document,
         output_format
       ) do
    if is_nil(current_document) do
      %{
        ok: false,
        format: output_format,
        title: title,
        error: "No active spreadsheet to revert in this group."
      }
    else
      previous_document = find_previous_document(chat_id, current_document)

      if is_nil(previous_document) do
        %{
          ok: false,
          format: output_format,
          title: title,
          error: "No previous spreadsheet version available to revert."
        }
      else
        with {:ok, csv_content} <- read_agent_document_file(previous_document),
             {columns, rows} <- parse_csv_content(csv_content),
             {:ok, storage, normalized_csv_content} <-
               write_spreadsheet_document_file(previous_document.title, columns, rows, output_format),
             {:ok, doc} <-
               persist_document_version(
                 chat_id,
                 previous_document.title,
                 output_format,
                 storage.relative_url,
                 storage.file_url,
                 columns,
                 length(rows),
                 merge_document_metadata(
                   build_spreadsheet_metadata("revert_last", current_document.version, body),
                   storage.metadata
                 ),
                 "revert",
                 user_id
               ) do
          spreadsheet_tool_response(
            doc,
            columns,
            rows,
            normalized_csv_content,
            "Reverted spreadsheet to previous content safely. A new version snapshot was created."
          )
        else
          {:error, reason} ->
            Logger.error("[GroupAgent] Failed to revert spreadsheet: #{inspect(reason)}")
            spreadsheet_error_response(title, reason, output_format)
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
    format =
      doc.format
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> case do
        "csv" -> "csv"
        _ -> "xlsx"
      end

    %{
      ok: true,
      title: doc.title,
      format: format,
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

  defp spreadsheet_error_response(title, reason, output_format \\ "xlsx") do
    %{
      ok: false,
      error: "Failed to handle spreadsheet file",
      reason: inspect(reason),
      format: if(output_format == "csv", do: "csv", else: "xlsx"),
      title: title
    }
  end

  defp document_tool_response(doc, format, content, note) do
    %{
      ok: true,
      title: doc.title,
      format: format,
      content: content,
      download_path: doc.relative_url,
      file_url: doc.file_url,
      version: doc.version,
      note: note
    }
  end

  defp document_error_response(title, format, reason) do
    %{
      ok: false,
      title: title,
      format: format,
      error: "Failed to create document",
      reason: inspect(reason)
    }
  end

  defp file_extension_for_document_format(format) do
    case format do
      "plain_text" -> "txt"
      "html" -> "html"
      "json" -> "json"
      _ -> "md"
    end
  end

  defp build_spreadsheet_metadata(operation, source_version, body) do
    %{
      "operation" => operation,
      "source_version" => source_version,
      "request_hint" => body |> to_string() |> String.slice(0, 300)
    }
  end

  defp build_document_metadata(format, body) do
    %{
      "operation" => "create_document",
      "format" => format,
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
    |> Enum.map(&normalize_spreadsheet_cell/1)
    |> fit_row_to_column_count(length(columns))
  end

  defp normalize_single_spreadsheet_row(raw_row, columns) when is_map(raw_row) do
    normalized_lookup =
      raw_row
      |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), normalize_spreadsheet_cell(v)} end)
      |> Map.new()

    columns
    |> Enum.map(fn col -> Map.get(normalized_lookup, String.downcase(col), "") end)
    |> fit_row_to_column_count(length(columns))
  end

  defp normalize_single_spreadsheet_row(raw_row, columns) when is_binary(raw_row) do
    raw_row
    |> String.split(~r/\s*,\s*/, trim: true)
    |> Enum.map(&normalize_spreadsheet_cell/1)
    |> fit_row_to_column_count(length(columns))
  end

  defp normalize_single_spreadsheet_row(_, _), do: nil

  defp fit_row_to_column_count(values, column_count) when is_list(values) and column_count >= 0 do
    trimmed =
      values
      |> Enum.map(&normalize_spreadsheet_cell/1)
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

  defp normalize_spreadsheet_cell(value) do
    value
    |> to_string()
    |> String.replace(~r/\r\n?|\n/, " ")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.trim()
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

  defp merge_document_metadata(base_metadata, storage_metadata) do
    base = if is_map(base_metadata), do: base_metadata, else: %{}
    storage = if is_map(storage_metadata), do: storage_metadata, else: %{}
    Map.merge(base, storage)
  end

  defp write_spreadsheet_document_file(title, columns, rows, output_format) do
    csv_content = csv_from_rows(columns, rows)
    resolved_format = if output_format == "csv", do: "csv", else: "xlsx"

    case resolved_format do
      "csv" ->
        with {:ok, storage} <- write_agent_document_file(title, csv_content, "csv") do
          {:ok, storage, csv_content}
        end

      _ ->
        with {:ok, xlsx_binary} <- xlsx_from_rows(columns, rows),
             {:ok, storage} <-
               write_agent_document_binary_file(
                 title,
                 xlsx_binary,
                 "xlsx",
                 %{
                   "spreadsheet_source_csv" => csv_content,
                   "spreadsheet_source_format" => "csv"
                 }
               ) do
          {:ok, storage, csv_content}
        end
    end
  end

  defp read_agent_document_file(%GroupAgentDocument{} = document) do
    metadata = if is_map(document.metadata), do: document.metadata, else: %{}

    case metadata["spreadsheet_source_csv"] || metadata[:spreadsheet_source_csv] do
      csv_source when is_binary(csv_source) and csv_source != "" ->
        {:ok, csv_source}

      _ ->
        case metadata["inline_content"] || metadata[:inline_content] do
          inline_content when is_binary(inline_content) ->
            {:ok, inline_content}

          _ ->
            read_agent_document_file(document.relative_url)
        end
    end
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
    columns
    |> sanitize_spreadsheet_columns()
    |> case do
      [] -> ["Item", "Value"]
      value -> value
    end
  end

  defp sanitize_spreadsheet_columns(columns) when is_list(columns) do
    normalized =
      columns
      |> Enum.with_index(1)
      |> Enum.map(fn {column, idx} ->
        column
        |> to_string()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> default_if_blank("Column #{idx}")
      end)

    {deduped, _seen} =
      Enum.map_reduce(normalized, %{}, fn column, seen ->
        key = String.downcase(column)
        count = Map.get(seen, key, 0) + 1
        next_seen = Map.put(seen, key, count)
        final_name = if count == 1, do: column, else: "#{column} (#{count})"
        {final_name, next_seen}
      end)

    deduped
  end

  defp sanitize_spreadsheet_columns(_), do: []

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
    if byte_size(to_string(content || "")) > @max_agent_document_bytes do
      {:error, :document_too_large}
    else
      filename = build_agent_document_filename(title, extension)
      blob_key = build_agent_document_blob_key()
      relative_url = "/api/agent/document/#{blob_key}/#{filename}"

      {:ok,
       %{
         relative_url: relative_url,
         file_url: public_upload_url(relative_url),
         metadata: %{
           "storage_kind" => "db_inline",
           "blob_key" => blob_key,
           "download_name" => filename,
           "content_type" => content_type_for_extension(extension),
           "inline_content" => to_string(content || "")
         }
       }}
    end
  end

  defp write_agent_document_binary_file(title, binary_content, extension, extra_metadata \\ %{}) do
    if !is_binary(binary_content) do
      {:error, :invalid_document_binary}
    else
      if byte_size(binary_content) > @max_agent_document_bytes do
        {:error, :document_too_large}
      else
        filename = build_agent_document_filename(title, extension)
        blob_key = build_agent_document_blob_key()
        relative_url = "/api/agent/document/#{blob_key}/#{filename}"

        metadata =
          %{
            "storage_kind" => "db_inline",
            "blob_key" => blob_key,
            "download_name" => filename,
            "content_type" => content_type_for_extension(extension),
            "inline_content_base64" => Base.encode64(binary_content)
          }
          |> Map.merge(if(is_map(extra_metadata), do: extra_metadata, else: %{}))

        {:ok,
         %{
           relative_url: relative_url,
           file_url: public_upload_url(relative_url),
           metadata: metadata
         }}
      end
    end
  end

  defp xlsx_from_rows(columns, rows) do
    sanitized_columns =
      columns
      |> sanitize_spreadsheet_columns()
      |> case do
        [] -> ["Item", "Value"]
        value -> value
      end

    sanitized_rows =
      rows
      |> align_rows_to_column_count(length(sanitized_columns))
      |> Enum.map(&Enum.map(&1, fn value -> normalize_spreadsheet_cell(value) end))

    sheet_rows = [sanitized_columns | sanitized_rows]

    entries = [
      {~c"[Content_Types].xml", xlsx_content_types_xml()},
      {~c"_rels/.rels", xlsx_root_rels_xml()},
      {~c"xl/workbook.xml", xlsx_workbook_xml()},
      {~c"xl/_rels/workbook.xml.rels", xlsx_workbook_rels_xml()},
      {~c"xl/styles.xml", xlsx_styles_xml()},
      {~c"xl/worksheets/sheet1.xml", xlsx_sheet_xml(sheet_rows)}
    ]

    case :zip.create(~c"spreadsheet.xlsx", entries, [:memory]) do
      {:ok, {_name, zip_binary}} when is_binary(zip_binary) ->
        {:ok, zip_binary}

      {:ok, zip_binary} when is_binary(zip_binary) ->
        {:ok, zip_binary}

      {:error, reason} ->
        {:error, {:xlsx_zip_create_failed, reason}}

      other ->
        {:error, {:xlsx_zip_unexpected_result, other}}
    end
  end

  defp xlsx_content_types_xml do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
      <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
    </Types>
    """
    |> String.trim()
  end

  defp xlsx_root_rels_xml do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """
    |> String.trim()
  end

  defp xlsx_workbook_xml do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets>
        <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
      </sheets>
    </workbook>
    """
    |> String.trim()
  end

  defp xlsx_workbook_rels_xml do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """
    |> String.trim()
  end

  defp xlsx_styles_xml do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <fonts count="2">
        <font>
          <sz val="11"/>
          <name val="Calibri"/>
        </font>
        <font>
          <b/>
          <sz val="11"/>
          <color rgb="FFFFFFFF"/>
          <name val="Calibri"/>
        </font>
      </fonts>
      <fills count="3">
        <fill><patternFill patternType="none"/></fill>
        <fill><patternFill patternType="gray125"/></fill>
        <fill><patternFill patternType="solid"><fgColor rgb="FF2B5797"/><bgColor indexed="64"/></patternFill></fill>
      </fills>
      <borders count="2">
        <border>
          <left/><right/><top/><bottom/><diagonal/>
        </border>
        <border>
          <left style="thin"><color auto="1"/></left>
          <right style="thin"><color auto="1"/></right>
          <top style="thin"><color auto="1"/></top>
          <bottom style="thin"><color auto="1"/></bottom>
          <diagonal/>
        </border>
      </borders>
      <cellStyleXfs count="1">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
      </cellStyleXfs>
      <cellXfs count="3">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
        <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
          <alignment horizontal="center" vertical="center" wrapText="1"/>
        </xf>
        <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1">
          <alignment vertical="center" wrapText="1"/>
        </xf>
      </cellXfs>
      <cellStyles count="1">
        <cellStyle name="Normal" xfId="0" builtinId="0"/>
      </cellStyles>
    </styleSheet>
    """
    |> String.trim()
  end

  defp xlsx_sheet_xml(rows) when is_list(rows) do
    col_count =
      case rows do
        [first | _] -> length(first)
        _ -> 1
      end

    cols_xml =
      1..col_count
      |> Enum.map_join("", fn i -> ~s(<col min="#{i}" max="#{i}" width="22" customWidth="1"/>) end)

    row_xml =
      rows
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {cells, row_index} ->
        # Row 1 = header (style 1), rest = data (style 2)
        style_id = if row_index == 1, do: "1", else: "2"

        cell_xml =
          cells
          |> Enum.with_index(1)
          |> Enum.map_join("", fn {value, col_index} ->
            xlsx_cell_xml(row_index, col_index, value, style_id)
          end)

        ~s(<row r="#{row_index}">#{cell_xml}</row>)
      end)

    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <sheetViews>
        <sheetView rightToLeft="true" workbookViewId="0"/>
      </sheetViews>
      <cols>#{cols_xml}</cols>
      <sheetData>#{row_xml}</sheetData>
    </worksheet>
    """
    |> String.trim()
  end

  defp xlsx_cell_xml(row_index, col_index, value, style_id \\ "0") do
    ref = excel_cell_ref(row_index, col_index)
    text = normalize_spreadsheet_cell(value)

    if text == "" do
      ~s(<c r="#{ref}" s="#{style_id}"/>)
    else
      preserve = if text != String.trim(text), do: ~s( xml:space="preserve"), else: ""
      escaped = xml_escape(text)
      ~s(<c r="#{ref}" s="#{style_id}" t="inlineStr"><is><t#{preserve}>#{escaped}</t></is></c>)
    end
  end

  defp excel_cell_ref(row_index, col_index) when row_index > 0 and col_index > 0 do
    excel_column_name(col_index) <> Integer.to_string(row_index)
  end

  defp excel_column_name(index) when index > 0 do
    do_excel_column_name(index, "")
  end

  defp do_excel_column_name(index, acc) when index > 0 do
    rem_value = rem(index - 1, 26)
    next_index = div(index - 1, 26)
    letter = <<rem_value + ?A>>
    do_excel_column_name(next_index, letter <> acc)
  end

  defp do_excel_column_name(0, acc), do: acc

  defp xml_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp build_agent_document_blob_key do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp content_type_for_extension(extension) do
    case extension |> to_string() |> String.trim() |> String.downcase() do
      "csv" -> "text/csv"
      "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      "xls" -> "application/vnd.ms-excel"
      "pdf" -> "application/pdf"
      "md" -> "text/markdown"
      "json" -> "application/json"
      "html" -> "text/html"
      "txt" -> "text/plain"
      _ -> "application/octet-stream"
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

    normalized_base = normalize_public_base_url(base_url)

    if is_binary(normalized_base) and normalized_base != "" do
      String.trim_trailing(normalized_base, "/") <> relative_url
    else
      relative_url
    end
  end

  defp normalize_public_base_url(raw) when is_binary(raw) do
    cleaned =
      raw
      |> String.trim()
      |> String.trim_leading("\"")
      |> String.trim_trailing("\"")
      |> String.trim_leading("'")
      |> String.trim_trailing("'")

    fixed_bracketed =
      case Regex.run(~r/^https?:\/\/\[(https?:\/\/[^\]]+)\](\/.*)?$/i, cleaned) do
        [_, inner, path] when is_binary(path) -> inner <> path
        [_, inner, nil] -> inner
        [_, inner] -> inner
        _ ->
          case Regex.run(~r/^\[(https?:\/\/[^\]]+)\](\/.*)?$/i, cleaned) do
            [_, inner, path] when is_binary(path) -> inner <> path
            [_, inner, nil] -> inner
            [_, inner] -> inner
            _ -> cleaned
          end
      end

    fixed_double_scheme =
      fixed_bracketed
      |> String.replace_prefix("https://https://", "https://")
      |> String.replace_prefix("http://http://", "http://")

    fixed_double_scheme
  end

  defp normalize_public_base_url(_), do: ""

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

  defp build_html_document(title, body) do
    escaped_title = escape_html(title)
    escaped_body = escape_html(body)

    body_html =
      escaped_body
      |> String.split(~r/\r?\n/, trim: false)
      |> Enum.map_join("\n", fn line ->
        trimmed = String.trim(line)
        cond do
          trimmed == "" -> ""
          String.starts_with?(trimmed, "## ") -> "<h2>#{String.trim_leading(trimmed, "## ")}</h2>"
          String.starts_with?(trimmed, "- ") -> "<li>#{String.trim_leading(trimmed, "- ")}</li>"
          true -> "<p>#{line}</p>"
        end
      end)

    """
    <!DOCTYPE html>
    <html dir="rtl" lang="fa">
    <head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
    <title>#{escaped_title}</title>
    <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Tahoma, Arial, sans-serif;
      font-size: 15px;
      line-height: 1.6;
      color: #1a1a1a;
      background: #ffffff;
      padding: 20px;
      direction: rtl;
      text-align: right;
    }
    h1 {
      font-size: 22px;
      font-weight: 700;
      color: #2B5797;
      margin-bottom: 16px;
      padding-bottom: 10px;
      border-bottom: 2px solid #2B5797;
    }
    h2 {
      font-size: 17px;
      font-weight: 600;
      color: #333;
      margin: 16px 0 8px;
    }
    p { margin: 6px 0; }
    li { margin: 4px 0 4px 20px; }
    table {
      width: 100%;
      border-collapse: collapse;
      margin: 16px 0;
      direction: rtl;
    }
    th {
      background: #2B5797;
      color: #fff;
      font-weight: 600;
      padding: 10px 12px;
      text-align: right;
      border: 1px solid #1e3f6f;
      white-space: nowrap;
    }
    td {
      padding: 8px 12px;
      border: 1px solid #d0d0d0;
      text-align: right;
      vertical-align: top;
    }
    tr:nth-child(even) td { background: #f5f7fa; }
    tr:hover td { background: #e8edf4; }
    .summary-row td {
      font-weight: 700;
      background: #eef2f8;
      border-top: 2px solid #2B5797;
    }
    </style>
    </head>
    <body>
    <h1>#{escaped_title}</h1>
    #{body_html}
    </body>
    </html>
    """
    |> String.trim()
  end

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

  defp maybe_attach_spreadsheet_fallback(
         chat_id,
         user_message,
         response,
         enabled_tools,
         user_id,
         existing_attachment \\ nil
       ) do
    cond do
      existing_attachment ->
        %{text: response, attachment: existing_attachment}

      should_auto_generate_spreadsheet?(chat_id, user_message, response, enabled_tools) ->
        title = infer_spreadsheet_title(user_message)
        operation = infer_fallback_spreadsheet_operation(user_message, chat_id)

        case create_document_tool(chat_id, %{
               "title" => title,
               "body" => user_message,
               "format" => "xlsx",
               "operation" => operation
             }, user_id) do
          %{ok: true, row_count: row_count} = result ->
            Logger.info(
              "[GroupAgent] Auto-generated spreadsheet fallback title=#{title} rows=#{row_count} operation=#{operation}"
            )

            fallback_message =
              spreadsheet_fallback_message(
                result[:file_url] || result["file_url"],
                row_count,
                result[:columns] || result["columns"] || []
              )

            resolved_text =
              if refusal_language?(response) do
                fallback_message
              else
                response <> "\n\n" <> fallback_message
              end

            %{text: resolved_text, attachment: attachment_from_document_result(result)}

          _ ->
            %{text: response, attachment: nil}
        end

      true ->
        %{text: response, attachment: nil}
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
      String.contains?(text, "/api/agent/document/") or
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

    "Created editable spreadsheet file (Excel .xlsx) and attached it.\nColumns: #{col_count}, Rows: #{row_count}\nYou can open it in Excel, Numbers, or Google Sheets."
  end

  defp extract_tool_attachment("create_document", result), do: attachment_from_document_result(result)
  defp extract_tool_attachment(_tool_name, _result), do: nil

  defp attachment_from_document_result(result) when is_map(result) do
    ok? =
      Map.get(result, :ok) ||
        Map.get(result, "ok")

    file_url =
      Map.get(result, :file_url) ||
        Map.get(result, "file_url") ||
        Map.get(result, :download_path) ||
        Map.get(result, "download_path")

    with true <- ok? == true,
         url when is_binary(url) <- normalize_attachment_url(file_url),
         true <- url != "" do
      file_name = derive_file_name_from_url(url) || "document"
      %{url: url, file_name: file_name}
    else
      _ -> nil
    end
  end

  defp attachment_from_document_result(_), do: nil

  defp normalize_attachment_url(value) when is_binary(value) do
    normalized = value |> String.trim()

    cond do
      normalized == "" ->
        nil

      String.starts_with?(normalized, "http://") or String.starts_with?(normalized, "https://") ->
        normalized

      String.starts_with?(normalized, "/") ->
        public_upload_url(normalized)

      true ->
        normalized
    end
  end

  defp normalize_attachment_url(_), do: nil

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
    Create a high-quality, production-ready system prompt for a group chat AI assistant.
    The prompt must be practical and concise for mobile chat, but with strong structure and execution rules.
    It should include tone, boundaries, response style, and how to use tools safely.
    Enabled tools for this assistant: #{tool_list}.

    Admin's high-level intent:
    #{user_input}

    Required prompt structure (use clear section headers):
    1) Role & Objective
    2) Response Contract (clarity, brevity, answer quality)
    3) Tool Usage Rules
    4) Spreadsheet & Document Standards
       - Prefer Excel (.xlsx) for spreadsheets unless user explicitly asks for csv.
       - Enforce clean columns, aligned rows, and normalized values.
       - Keep professional naming and consistent data formatting.
    5) Clarification Policy (when to ask follow-up questions)
    6) Safety & Boundaries
    7) Two short examples:
       - one normal chat response example
       - one spreadsheet-generation behavior example

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

    Role & Objective:
    #{user_input}

    Response Contract:
    - Prioritize direct, useful answers in short mobile-friendly format.
    - Avoid generic wording; be specific, actionable, and context-aware.
    - If intent is ambiguous, ask focused clarifying questions.

    Tool Usage Rules:
    - Use enabled tools whenever they materially improve accuracy or output quality.
    - If a requested action requires a disabled tool, state that clearly and offer alternatives.

    Spreadsheet & Document Standards:
    - For spreadsheet requests, default to Excel (.xlsx) unless user explicitly asks for csv.
    - Use clear professional column names and stable column order.
    - Keep each row aligned to the column schema (no missing/extra cells).
    - Normalize noisy data (trim spaces, consistent wording, remove filler placeholders).
    - Prefer consistent date/amount formats across rows.

    Clarification Policy:
    - Ask a short follow-up when key schema fields are missing.
    - If reasonable assumptions are needed, state them briefly.
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

  defp broadcast_agent_message(chat_id, agent_config, text, user_id, metadata, explicit_attachment \\ nil) do
    Logger.info(
      "[GroupAgent] Broadcasting agent message chat_id=#{chat_id} len=#{String.length(text || "")}"
    )

    message_id = Ecto.UUID.generate()
    timestamp = :os.system_time(:millisecond)
    reply_to_id = Map.get(metadata, "reply_to_id")
    attachment =
      normalize_explicit_attachment(explicit_attachment) ||
        extract_agent_document_attachment(chat_id, text)
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
            encrypted_content: AgentMessageCrypto.encrypt_for_storage(plain_text),
            type: message_type,
            timestamp: timestamp,
            reply_to_id: reply_to_id
          }

          message_attrs =
            case attachment do
              %{url: url} -> Map.put(message_attrs_base, :media_url, url)
              _ -> message_attrs_base
            end

          case Vibe.Chat.add_message(message_attrs, acting_user_id: user_id) do
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

  defp normalize_explicit_attachment(%{url: url, file_name: file_name}) do
    with normalized_url when is_binary(normalized_url) <- normalize_attachment_url(url),
         true <- normalized_url != "" do
      resolved_name =
        file_name
        |> to_string()
        |> String.trim()
        |> case do
          "" -> derive_file_name_from_url(normalized_url) || "document"
          value -> value
        end

      %{url: normalized_url, file_name: resolved_name}
    else
      _ -> nil
    end
  end

  defp normalize_explicit_attachment(_), do: nil

  defp extract_agent_document_url(text, chat_id) do
    normalized_text = text |> to_string()

    absolute =
      Regex.scan(~r/https?:\/\/[^\s)]+/i, normalized_text)
      |> List.flatten()
      |> Enum.find(fn url ->
        String.contains?(url, "/uploads/#{@agent_docs_dir}/")
          || String.contains?(url, "/api/agent/document/")
      end)

    relative =
      Regex.scan(~r/(?:\/uploads\/agent-docs\/[^\s)]+|\/api\/agent\/document\/[^\s)]+)/i, normalized_text)
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
            %GroupAgentDocument{} = document ->
              case current_document_url(document) do
                url when is_binary(url) and url != "" -> {:ok, url}
                _ -> {:error, :not_found}
              end

            _ ->
              {:error, :not_found}
          end
        else
          {:error, :not_found}
        end
    end
  end

  defp current_document_url(%GroupAgentDocument{} = document) do
    metadata = if is_map(document.metadata), do: document.metadata, else: %{}
    blob_key = metadata["blob_key"] || metadata[:blob_key]
    download_name = metadata["download_name"] || metadata[:download_name]

    cond do
      is_binary(blob_key) and String.trim(blob_key) != "" ->
        key = String.trim(blob_key)
        name =
          download_name
          |> to_string()
          |> String.trim()
          |> default_if_blank("document")

        public_upload_url("/api/agent/document/#{key}/#{name}")

      is_binary(document.relative_url) and document.relative_url != "" ->
        normalize_attachment_url(document.relative_url)

      is_binary(document.file_url) and document.file_url != "" ->
        normalize_attachment_url(document.file_url)

      true ->
        nil
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
    |> String.replace(~r/https?:\/\/[^\s)]*\/api\/agent\/document\/[^\s)]+/i, "")
    |> String.replace(~r/\/api\/agent\/document\/[^\s)]+/i, "")
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

  defp maybe_compact(chat_id, user_id) do
    Task.start(fn ->
      case GroupAgentMemory.get_or_create(chat_id, acting_user_id: user_id) do
        {:ok, memory} when length(memory.messages) > @compaction_threshold ->
          compact_memory(memory, user_id)
        _ ->
          :ok
      end
    end)
  end

  defp compact_memory(memory, user_id) do
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
        GroupAgentMemory.update_after_compaction(
          memory,
          String.trim(summary),
          to_keep,
          acting_user_id: user_id
        )
        Logger.info("[GroupAgent] Memory compacted for chat #{memory.chat_id}: #{length(to_compact)} messages summarized")

      {:error, reason} ->
        Logger.error("[GroupAgent] Memory compaction failed for chat #{memory.chat_id}: #{inspect(reason)}")
    end
  end
end
