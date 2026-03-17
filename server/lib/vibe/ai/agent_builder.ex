defmodule Vibe.AI.AgentBuilder do
  @moduledoc false

  require Logger

  alias Vibe.Agents
  alias Vibe.AgentConversation
  alias Vibe.AI.GroupAgent
  alias Vibe.AI.ToolRegistry

  @builder_deep_link "vibe://agent?mode=builder"
  @claude_api "https://api.anthropic.com/v1/messages"
  @claude_model "claude-haiku-4-5-20251001"
  @max_tool_depth 6

  @builder_tools [
    %{
      name: "get_builder_context",
      description:
        "Read the owner's current builder state, agent list, quota, selected agent, prompt status, and integration data. Use this before answering setup or integration questions.",
      input_schema: %{
        type: "object",
        properties: %{
          identifier: %{
            type: "string",
            description: "Optional agent id or @username to inspect instead of the currently selected draft."
          }
        }
      }
    },
    %{
      name: "create_agent",
      description:
        "Create a new standalone Vibe agent draft. Use when the owner asks to create a new agent in plain language or with slash shorthand like /newagent.",
      input_schema: %{
        type: "object",
        properties: %{
          display_name: %{type: "string", description: "Human-readable display name for the draft."},
          username: %{type: "string", description: "Optional public username without @."},
          description: %{
            type: "string",
            description:
              "Optional natural-language description of how the agent should behave. If provided, this tool should generate a system prompt for the new draft."
          },
          system_prompt: %{type: "string", description: "Optional final system prompt to save immediately."},
          persona: %{type: "string", description: "Optional persona or character summary."},
          callback_url: %{type: "string", description: "Optional callback URL. Use 'off' only when updating an existing agent, not during creation."},
          enabled_tools: %{
            type: "array",
            items: %{type: "string"},
            description: "Optional tool ids to enable."
          },
          output_modes: %{
            type: "array",
            items: %{type: "string"},
            description: "Optional output modes from text, media, voice."
          },
          voice_profile: %{type: "string", description: "Optional voice profile, for example alloy."}
        }
      }
    },
    %{
      name: "select_agent",
      description:
        "Select an existing owned agent by id or @username so later updates, publishing, and integration answers use that agent.",
      input_schema: %{
        type: "object",
        properties: %{
          identifier: %{type: "string", description: "Agent id or @username to select."}
        },
        required: ["identifier"]
      }
    },
    %{
      name: "update_agent",
      description:
        "Update the selected agent or a specific agent. Use this for name, username, prompt, persona, webhook, tool list, voice mode, or general reconfiguration. Slash commands are only shorthand; still use this tool.",
      input_schema: %{
        type: "object",
        properties: %{
          identifier: %{type: "string", description: "Optional target agent id or @username. Defaults to the selected draft."},
          display_name: %{type: "string", description: "Updated display name."},
          username: %{type: "string", description: "Updated public username without @."},
          description: %{
            type: "string",
            description:
              "Optional natural-language behavior description. If present, this tool should generate and save an updated system prompt."
          },
          system_prompt: %{type: "string", description: "Updated final system prompt."},
          persona: %{type: "string", description: "Updated persona summary."},
          callback_url: %{
            type: "string",
            description: "Updated callback URL. Use 'off' to disable callbacks."
          },
          enabled_tools: %{
            type: "array",
            items: %{type: "string"},
            description: "Tool ids to enable."
          },
          output_modes: %{
            type: "array",
            items: %{type: "string"},
            description: "Output modes from text, media, voice."
          },
          voice_profile: %{type: "string", description: "Voice profile like alloy."},
          welcome_message: %{type: "string", description: "Optional welcome message for the agent."}
        }
      }
    },
    %{
      name: "generate_system_prompt",
      description:
        "Generate a production-quality system prompt from a plain-language description without saving it yet. Use this when the owner asks you to draft or improve the prompt.",
      input_schema: %{
        type: "object",
        properties: %{
          description: %{type: "string", description: "What the agent should do and how it should behave."},
          enabled_tools: %{
            type: "array",
            items: %{type: "string"},
            description: "Optional tool ids to optimize the prompt for."
          }
        },
        required: ["description"]
      }
    },
    %{
      name: "publish_agent",
      description:
        "Publish the selected agent or a specific agent when it is ready for use.",
      input_schema: %{
        type: "object",
        properties: %{
          identifier: %{type: "string", description: "Optional agent id or @username. Defaults to the selected draft."}
        }
      }
    },
    %{
      name: "set_agent_status",
      description:
        "Set agent status to draft, published, or disabled. Use this for disable/enable requests.",
      input_schema: %{
        type: "object",
        properties: %{
          identifier: %{type: "string", description: "Optional agent id or @username. Defaults to the selected draft."},
          status: %{type: "string", enum: ["draft", "published", "disabled"], description: "New agent status."}
        },
        required: ["status"]
      }
    },
    %{
      name: "rotate_secret",
      description:
        "Rotate the invoke secret for the selected agent or a specific agent. Use this when the owner asks for the current secret or wants a new one.",
      input_schema: %{
        type: "object",
        properties: %{
          identifier: %{type: "string", description: "Optional agent id or @username. Defaults to the selected draft."}
        }
      }
    },
    %{
      name: "get_integration_details",
      description:
        "Read the exact integration details for an agent, including agent id, user id, username, invoke URL, responseMode guidance, callback signing, and attached vibeChatId values.",
      input_schema: %{
        type: "object",
        properties: %{
          identifier: %{type: "string", description: "Optional agent id or @username. Defaults to the selected draft."}
        }
      }
    }
  ]

  def handle_message(user_id, message, opts \\ []) do
    active_agent_id = Keyword.get(opts, :active_agent_id)

    with {:ok, session} <- Agents.get_or_create_builder_session(user_id) do
      history = session.messages || []

      _ =
        AgentConversation.add_message(session.id, %{
          "role" => "user",
          "content" => message
        })

      with {:ok, result} <- run_builder_agent(user_id, history, message, active_agent_id) do
        reply = result.reply
        next_active_agent_id = result.active_agent_id
        latest_secret = result.latest_secret

        _ =
          AgentConversation.add_message(session.id, %{
            "role" => "assistant",
            "content" => reply
          })

        selected_agent =
          if is_binary(next_active_agent_id) do
            Agents.get_agent(next_active_agent_id, user_id)
          end

        payload = if selected_agent, do: Agents.agent_payload(selected_agent), else: %{}

        metadata =
          (session.metadata || %{})
          |> Map.put("kind", Agents.builder_kind())
          |> Map.put("active_agent_id", next_active_agent_id)
          |> Map.put("draft_state", payload)

        {:ok, updated_session} = Agents.update_builder_session(session, %{metadata: metadata})

        {:ok,
         %{
           conversationId: updated_session.id,
           activeAgentId: next_active_agent_id,
           reply: reply,
           suggestions: default_suggestions(selected_agent),
           draftPatch: payload,
           agent: if(selected_agent, do: payload, else: nil),
           latestSecret: latest_secret
         }}
      end
    end
  end

  def session_payload(user_id) do
    with {:ok, session} <- Agents.get_or_create_builder_session(user_id) do
      active_agent_id = session.metadata && session.metadata["active_agent_id"]
      active_agent = if is_binary(active_agent_id), do: Agents.get_agent(active_agent_id, user_id), else: nil

      {:ok,
       %{
         conversationId: session.id,
         activeAgentId: active_agent_id,
         messages: session.messages || [],
         draftPatch: if(active_agent, do: Agents.agent_payload(active_agent), else: %{}),
         agent: if(active_agent, do: Agents.agent_payload(active_agent), else: nil),
         suggestions: default_suggestions(active_agent)
       }}
    end
  end

  defp run_builder_agent(user_id, history, message, active_agent_id) do
    api_key = anthropic_api_key()

    if is_nil(api_key) do
      {:error, "Builder AI is unavailable because ANTHROPIC_API_KEY is not configured."}
    else
      messages = build_builder_messages(history, message)
      state = %{user_id: user_id, active_agent_id: active_agent_id, latest_secret: nil}

      with {:ok, raw_reply, final_state} <- run_builder_loop(messages, state, api_key, 0) do
        selected_agent = resolve_owned_agent(user_id, nil, final_state.active_agent_id)
        reply = normalize_optional_string(raw_reply) || fallback_reply(selected_agent)

        {:ok,
         %{
           reply: reply,
           active_agent_id: final_state.active_agent_id,
           latest_secret: final_state.latest_secret
         }}
      end
    end
  end

  defp run_builder_loop(_messages, _state, _api_key, depth) when depth > @max_tool_depth do
    {:error, "Builder AI reached the maximum tool depth."}
  end

  defp run_builder_loop(messages, state, api_key, depth) do
    case request_builder_completion(messages, state, api_key) do
      {:ok, reply} ->
        {:ok, reply, state}

      {:tool_use, content_blocks} ->
        {tool_results, next_state} = execute_builder_tools(content_blocks, state)

        run_builder_loop(
          messages ++ [
            %{role: "assistant", content: content_blocks},
            %{role: "user", content: tool_results}
          ],
          next_state,
          api_key,
          depth + 1
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_builder_completion(messages, state, api_key) do
    body =
      Jason.encode!(%{
        model: @claude_model,
        max_tokens: 1600,
        system: builder_system_prompt(state),
        tools: @builder_tools,
        messages: messages
      })

    headers = [
      {"content-type", "application/json"},
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"}
    ]

    request = Finch.build(:post, @claude_api, headers, body)

    case Finch.request(request, Vibe.Finch, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"content" => content_blocks}} when is_list(content_blocks) ->
            if Enum.any?(content_blocks, &(&1["type"] == "tool_use")) do
              {:tool_use, content_blocks}
            else
              {:ok, extract_text_reply(content_blocks)}
            end

          {:ok, _decoded} ->
            {:error, "Builder AI returned an invalid response."}

          {:error, decode_error} ->
            Logger.error("[AgentBuilder] Failed to decode Claude response: #{inspect(decode_error)}")
            {:error, "Builder AI returned unreadable JSON."}
        end

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("[AgentBuilder] Claude API error status=#{status} body=#{response_body}")
        {:error, "Builder AI request failed with status #{status}."}

      {:error, reason} ->
        Logger.error("[AgentBuilder] Claude request failed: #{inspect(reason)}")
        {:error, "Builder AI request failed."}
    end
  end

  defp execute_builder_tools(content_blocks, state) do
    content_blocks
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> Enum.reduce({[], state}, fn tool, {results, acc_state} ->
      {result, next_state} = execute_builder_tool(tool["name"], tool["input"] || %{}, acc_state)

      tool_result = %{
        type: "tool_result",
        tool_use_id: tool["id"],
        content: Jason.encode!(result)
      }

      {results ++ [tool_result], next_state}
    end)
  end

  defp execute_builder_tool("get_builder_context", input, state) do
    user_id = state.user_id
    identifier = normalize_optional_string(Map.get(input, "identifier"))
    agent = resolve_owned_agent(user_id, identifier, state.active_agent_id)

    {builder_context_payload(user_id, agent, state.latest_secret), state}
  end

  defp execute_builder_tool("create_agent", input, state) do
    user_id = state.user_id

    attrs =
      input
      |> build_create_attrs()
      |> maybe_apply_generated_prompt(Map.get(input, "description"))

    case Agents.create_agent(user_id, attrs) do
      {:ok, agent, secret} ->
        result = %{
          "ok" => true,
          "message" => "Agent draft created.",
          "agent" => builder_agent_context(agent, secret)
        }

        {result, %{state | active_agent_id: agent.id, latest_secret: secret}}

      {:error, reason} ->
        {%{"ok" => false, "error" => format_reason(reason)}, state}
    end
  end

  defp execute_builder_tool("select_agent", input, state) do
    user_id = state.user_id
    identifier = normalize_optional_string(Map.get(input, "identifier"))

    case resolve_owned_agent(user_id, identifier, state.active_agent_id) do
      %{} = agent ->
        result = %{
          "ok" => true,
          "message" => "Selected agent.",
          "agent" => builder_agent_context(agent, state.latest_secret)
        }

        {result, %{state | active_agent_id: agent.id}}

      nil ->
        {%{"ok" => false, "error" => "Agent not found."}, state}
    end
  end

  defp execute_builder_tool("update_agent", input, state) do
    user_id = state.user_id
    identifier = normalize_optional_string(Map.get(input, "identifier"))

    with %{} = agent <- resolve_owned_agent(user_id, identifier, state.active_agent_id) do
      attrs =
        input
        |> build_update_attrs()
        |> maybe_apply_generated_prompt(Map.get(input, "description"), agent)

      case Agents.update_agent(agent, attrs, user_id) do
        {:ok, updated} ->
          result = %{
            "ok" => true,
            "message" => "Agent updated.",
            "agent" => builder_agent_context(updated, state.latest_secret)
          }

          {result, %{state | active_agent_id: updated.id}}

        {:error, reason} ->
          {%{"ok" => false, "error" => format_reason(reason)}, state}
      end
    else
      nil ->
        {%{"ok" => false, "error" => "Create or select an agent first."}, state}
    end
  end

  defp execute_builder_tool("generate_system_prompt", input, state) do
    description = normalize_optional_string(Map.get(input, "description"))
    enabled_tools = normalize_string_list(Map.get(input, "enabled_tools")) || Agents.default_enabled_tools()

    if is_nil(description) do
      {%{"ok" => false, "error" => "description is required"}, state}
    else
      case GroupAgent.generate_system_prompt(description, enabled_tools) do
        {:ok, prompt} ->
          result = %{
            "ok" => true,
            "system_prompt" => prompt,
            "persona_suggestion" => build_persona_suggestion(description),
            "enabled_tools" => enabled_tools
          }

          {result, state}

        {:error, reason} ->
          {%{"ok" => false, "error" => format_reason(reason)}, state}
      end
    end
  end

  defp execute_builder_tool("publish_agent", input, state) do
    user_id = state.user_id
    identifier = normalize_optional_string(Map.get(input, "identifier"))

    with %{} = agent <- resolve_owned_agent(user_id, identifier, state.active_agent_id) do
      case Agents.publish_agent(agent, user_id) do
        {:ok, published} ->
          result = %{
            "ok" => true,
            "message" => "Agent published.",
            "agent" => builder_agent_context(published, state.latest_secret),
            "integration" => integration_payload(published, state.latest_secret)
          }

          {result, %{state | active_agent_id: published.id}}

        {:error, reason} ->
          {%{"ok" => false, "error" => format_reason(reason)}, state}
      end
    else
      nil ->
        {%{"ok" => false, "error" => "Create or select an agent first."}, state}
    end
  end

  defp execute_builder_tool("set_agent_status", input, state) do
    user_id = state.user_id
    identifier = normalize_optional_string(Map.get(input, "identifier"))
    requested_status = normalize_optional_string(Map.get(input, "status")) || "draft"

    with %{} = agent <- resolve_owned_agent(user_id, identifier, state.active_agent_id) do
      result =
        case requested_status do
          "published" ->
            Agents.publish_agent(agent, user_id)

          "disabled" ->
            Agents.update_agent(agent, %{"status" => "disabled"}, user_id)

          "draft" ->
            Agents.update_agent(agent, %{"status" => "draft"}, user_id)

          _ ->
            {:error, :invalid_status}
        end

      case result do
        {:ok, updated} ->
          payload = %{
            "ok" => true,
            "message" => "Agent status updated.",
            "agent" => builder_agent_context(updated, state.latest_secret)
          }

          {payload, %{state | active_agent_id: updated.id}}

        {:error, reason} ->
          {%{"ok" => false, "error" => format_reason(reason)}, state}
      end
    else
      nil ->
        {%{"ok" => false, "error" => "Create or select an agent first."}, state}
    end
  end

  defp execute_builder_tool("rotate_secret", input, state) do
    user_id = state.user_id
    identifier = normalize_optional_string(Map.get(input, "identifier"))

    with %{} = agent <- resolve_owned_agent(user_id, identifier, state.active_agent_id) do
      case Agents.rotate_secret(agent, user_id) do
        {:ok, updated, secret} ->
          result = %{
            "ok" => true,
            "message" => "Secret rotated.",
            "secret" => secret,
            "agent" => builder_agent_context(updated, secret),
            "integration" => integration_payload(updated, secret)
          }

          {result, %{state | active_agent_id: updated.id, latest_secret: secret}}

        {:error, reason} ->
          {%{"ok" => false, "error" => format_reason(reason)}, state}
      end
    else
      nil ->
        {%{"ok" => false, "error" => "Create or select an agent first."}, state}
    end
  end

  defp execute_builder_tool("get_integration_details", input, state) do
    user_id = state.user_id
    identifier = normalize_optional_string(Map.get(input, "identifier"))

    case resolve_owned_agent(user_id, identifier, state.active_agent_id) do
      %{} = agent ->
        result = %{
          "ok" => true,
          "integration" => integration_payload(agent, state.latest_secret),
          "agent" => builder_agent_context(agent, state.latest_secret)
        }

        {result, state}

      nil ->
        {%{"ok" => false, "error" => "Create or select an agent first."}, state}
    end
  end

  defp execute_builder_tool(_tool_name, _input, state) do
    {%{"ok" => false, "error" => "Unknown builder tool."}, state}
  end

  defp build_builder_messages(history, message) do
    history
    |> Enum.take(-12)
    |> Enum.map(&normalize_history_message/1)
    |> Enum.reject(&is_nil/1)
    |> Kernel.++([%{role: "user", content: String.slice(String.trim(message), 0, 4_000)}])
  end

  defp normalize_history_message(%{"role" => role, "content" => content})
       when role in ["user", "assistant"] and is_binary(content) do
    %{role: role, content: String.slice(String.trim(content), 0, 4_000)}
  end

  defp normalize_history_message(%{role: role, content: content})
       when role in ["user", "assistant"] and is_binary(content) do
    %{role: role, content: String.slice(String.trim(content), 0, 4_000)}
  end

  defp normalize_history_message(_), do: nil

  defp builder_system_prompt(state) do
    """
    You are @vibeagent, the standalone Vibe agent builder inside the main chat UI.

    Operate in a fully agentic way:
    - Slash input like /newagent, /publish, /secret rotate, /webhook off, or /prompt is only shorthand from the user.
    - Never rely on command parsing. Interpret the message semantically and use tools to do the work.
    - Never claim an agent was created, updated, published, disabled, or rotated unless a tool result confirms it.
    - Use tools whenever you need agent state, ids, URLs, prompts, secrets, attached vibeChatId values, or integration guidance.
    - Before answering setup or integration questions, call get_builder_context or get_integration_details.
    - When the user describes how the agent should behave, create or update the agent and generate a polished production system prompt.
    - When the user asks about prompt quality, explain that you can read, edit, or generate the prompt and then act with tools.
    - When the user asks how to integrate from code, give exact values from tools: agent_id, user_id, @username, invoke URL, X-Vibe-Agent-Secret usage, responseMode guidance, vibeChatId values, callback headers, and signature format.
    - If the current secret is not available anymore, tell the user to rotate it.
    - Keep replies concise, practical, and step-by-step when integration is involved.

    Current client-selected active_agent_id: #{state.active_agent_id || "none"}
    Builder deep link: #{@builder_deep_link}
    Reserved setup handle: @vibeagent
    """
    |> String.trim()
  end

  defp build_create_attrs(input) do
    %{}
    |> maybe_put("display_name", normalize_optional_string(Map.get(input, "display_name")) || "New Agent")
    |> maybe_put("username", normalize_optional_string(Map.get(input, "username")))
    |> maybe_put("system_prompt", normalize_optional_string(Map.get(input, "system_prompt")))
    |> maybe_put("persona", normalize_optional_string(Map.get(input, "persona")))
    |> maybe_put("callback_url", normalize_callback_input(Map.get(input, "callback_url")))
    |> maybe_put("enabled_tools", normalize_string_list(Map.get(input, "enabled_tools")))
    |> maybe_put("output_modes", normalize_string_list(Map.get(input, "output_modes")))
    |> maybe_put("voice_profile", normalize_optional_string(Map.get(input, "voice_profile")))
  end

  defp build_update_attrs(input) do
    %{}
    |> maybe_put("display_name", normalize_optional_string(Map.get(input, "display_name")))
    |> maybe_put("username", normalize_optional_string(Map.get(input, "username")))
    |> maybe_put("system_prompt", normalize_optional_string(Map.get(input, "system_prompt")))
    |> maybe_put("persona", normalize_optional_string(Map.get(input, "persona")))
    |> maybe_put("callback_url", normalize_callback_input(Map.get(input, "callback_url")))
    |> maybe_put("enabled_tools", normalize_string_list(Map.get(input, "enabled_tools")))
    |> maybe_put("output_modes", normalize_string_list(Map.get(input, "output_modes")))
    |> maybe_put("voice_profile", normalize_optional_string(Map.get(input, "voice_profile")))
    |> maybe_put("welcome_message", normalize_optional_string(Map.get(input, "welcome_message")))
  end

  defp maybe_apply_generated_prompt(attrs, nil), do: attrs

  defp maybe_apply_generated_prompt(attrs, description) do
    maybe_apply_generated_prompt(attrs, description, nil)
  end

  defp maybe_apply_generated_prompt(attrs, description, agent) do
    description = normalize_optional_string(description)

    cond do
      is_nil(description) ->
        attrs

      Map.get(attrs, "system_prompt") && String.trim(Map.get(attrs, "system_prompt")) != "" ->
        attrs

      true ->
        enabled_tools =
          Map.get(attrs, "enabled_tools") ||
            if(agent, do: agent.enabled_tools, else: nil) ||
            Agents.default_enabled_tools()

        case GroupAgent.generate_system_prompt(description, enabled_tools) do
          {:ok, generated_prompt} ->
            attrs
            |> Map.put("system_prompt", generated_prompt)
            |> Map.put_new("persona", build_persona_suggestion(description))

          {:error, _reason} ->
            attrs
        end
    end
  end

  defp resolve_owned_agent(user_id, identifier, active_agent_id) do
    normalized_identifier = normalize_optional_string(identifier)

    cond do
      is_binary(normalized_identifier) ->
        find_owned_agent(user_id, normalized_identifier)

      is_binary(active_agent_id) ->
        Agents.get_agent(active_agent_id, user_id)

      true ->
        nil
    end
  end

  defp find_owned_agent(user_id, identifier) do
    Agents.get_agent(identifier, user_id) ||
      case Agents.get_agent_by_username(identifier) do
        %{} = agent when agent.owner_user_id == user_id -> agent
        _ -> nil
      end
  end

  defp builder_context_payload(user_id, agent, latest_secret) do
    %{
      "builder" => %{
        "handle" => "@vibeagent",
        "deep_link" => @builder_deep_link,
        "slash_mode" => "optional"
      },
      "quota" => Agents.quota_for_user(user_id),
      "default_enabled_tools" => Agents.default_enabled_tools(),
      "default_output_modes" => Agents.default_output_modes(),
      "available_tools" => Enum.map(ToolRegistry.tools(), &tool_catalog_payload/1),
      "agents" => Enum.map(Agents.list_agents(user_id), &agent_list_payload/1),
      "active_agent" => if(agent, do: builder_agent_context(agent, latest_secret), else: nil)
    }
  end

  defp tool_catalog_payload(tool) do
    %{
      "id" => tool.id,
      "name" => tool.name,
      "description" => tool.description
    }
  end

  defp agent_list_payload(agent) do
    payload = Agents.agent_payload(agent)

    %{
      "id" => payload.id,
      "display_name" => payload.displayName,
      "username" => payload.username,
      "status" => payload.status,
      "has_prompt" => String.trim(payload.systemPrompt || "") != ""
    }
  end

  defp builder_agent_context(agent, latest_secret) do
    payload = Agents.agent_payload(agent)

    %{
      "agent" => payload,
      "prompt_status" => prompt_status_line(agent),
      "open_link" => "vibe://chat?friendId=#{payload.userId}",
      "builder_link" => @builder_deep_link,
      "integration" => integration_payload(agent, latest_secret)
    }
  end

  defp integration_payload(agent, latest_secret) do
    payload = Agents.agent_payload(agent)

    %{
      "agent_id" => payload.id,
      "user_id" => payload.userId,
      "username" => payload.username,
      "display_name" => payload.displayName,
      "status" => payload.status,
      "open_link" => "vibe://chat?friendId=#{payload.userId}",
      "builder_link" => @builder_deep_link,
      "invoke_url" => build_invoke_url(agent),
      "secret_hint" => payload.secretHint,
      "latest_secret" => latest_secret,
      "secret_note" =>
        if(is_binary(latest_secret), do: "Use the latest_secret value below.", else: "The full secret is only shown right after creation or rotation. Rotate it if you need a new copy."),
      "auth_header" => %{"X-Vibe-Agent-Secret" => latest_secret || "<rotate_secret_to_reveal>"},
      "request_body_examples" => %{
        "reply" => %{
          "source" => "external",
          "message" => "Hello",
          "responseMode" => "reply"
        },
        "send" => %{
          "source" => "external",
          "vibeChatId" => "<attached_chat_id>",
          "message" => "Hello",
          "responseMode" => "send"
        }
      },
      "attached_chats" => payload.attachedChats || [],
      "attached_chat_ids" => Enum.map(payload.attachedChats || [], &extract_chat_id/1),
      "callback_url" => payload.callbackUrl,
      "callback_headers" => [
        "X-Vibe-Agent-Signature-Timestamp",
        "X-Vibe-Agent-Signature"
      ],
      "callback_signature" => "hex(hmac_sha256(secret, \"<timestamp>.<raw_body>\"))",
      "notes" => [
        "Use responseMode=reply for stateless replies returned directly to your backend.",
        "Use responseMode=send only when the agent is already attached to the target Vibe chat.",
        "To get a vibeChatId, DM the agent or invite it into a group/channel first."
      ]
    }
  end

  defp extract_chat_id(chat) when is_map(chat) do
    chat[:chatId] || chat["chatId"] || chat[:chat_id] || chat["chat_id"]
  end

  defp extract_chat_id(_chat), do: nil

  defp build_invoke_url(agent) do
    base = public_base_url()
    path = "/api/agents/#{agent.id}/invoke"

    if base == "" do
      path
    else
      String.trim_trailing(base, "/") <> path
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

  defp default_suggestions(nil) do
    [
      "Create an agent for customer support that can reply with text and voice.",
      "/newagent Product Copilot",
      "How do I call this agent from my backend and webhook?",
      "Draft a strong system prompt for a recruiting assistant."
    ]
  end

  defp default_suggestions(agent) do
    if String.trim(agent.system_prompt || "") == "" do
      [
        "Write the system prompt for an agent that books salon appointments.",
        "Make this agent sound like a calm legal intake assistant.",
        "/publish",
        "Show me the invoke URL and chat ids I can use."
      ]
    else
      [
        "How do I integrate this agent from code?",
        "Rotate the secret for this agent.",
        "Disable callbacks for now.",
        "/publish"
      ]
    end
  end

  defp prompt_status_line(agent) do
    if String.trim(agent.system_prompt || "") == "" do
      "No prompt yet. I can read, edit, or generate it from plain language."
    else
      "Prompt is ready. I can still rewrite it, add character, or tighten the instructions."
    end
  end

  defp fallback_reply(nil) do
    "Tell me what kind of agent you want and I’ll build it here."
  end

  defp fallback_reply(agent) do
    "Updated #{agent.display_name}. #{prompt_status_line(agent)}"
  end

  defp build_persona_suggestion(description) do
    description
    |> to_string()
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.slice(0, 140)
  end

  defp extract_text_reply(content_blocks) do
    content_blocks
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
    |> String.trim()
  end

  defp anthropic_api_key do
    System.get_env("ANTHROPIC_API_KEY") || System.get_env("CLAUDE_API_KEY")
  end

  defp normalize_callback_input(nil), do: nil

  defp normalize_callback_input(value) when is_binary(value) do
    trimmed = String.trim(value)

    case String.downcase(trimmed) do
      "" -> nil
      "off" -> nil
      "disable" -> nil
      "disabled" -> nil
      _ -> trimmed
    end
  end

  defp normalize_callback_input(value) do
    value
    |> to_string()
    |> normalize_callback_input()
  end

  defp normalize_string_list(nil), do: nil

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      items -> items
    end
  end

  defp normalize_string_list(value) when is_binary(value) do
    value
    |> String.split(~r/[\n,|]/, trim: true)
    |> normalize_string_list()
  end

  defp normalize_string_list(_), do: nil

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(value) do
    value
    |> to_string()
    |> normalize_optional_string()
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
