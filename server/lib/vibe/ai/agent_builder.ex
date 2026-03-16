defmodule Vibe.AI.AgentBuilder do
  @moduledoc false

  alias Vibe.Agents
  alias Vibe.AgentConversation
  alias Vibe.AI.GroupAgent

  def handle_message(user_id, message, opts \\ []) do
    active_agent_id = Keyword.get(opts, :active_agent_id)

    with {:ok, session} <- Agents.get_or_create_builder_session(user_id) do
      _ =
        AgentConversation.add_message(session.id, %{
          "role" => "user",
          "content" => message
        })

      {reply, agent, draft_patch, next_active_agent_id} =
        if String.starts_with?(String.trim(message), "/") do
          handle_command(user_id, message, active_agent_id)
        else
          handle_freeform(user_id, message, active_agent_id)
        end

      _ =
        AgentConversation.add_message(session.id, %{
          "role" => "assistant",
          "content" => reply
        })

      metadata =
        (session.metadata || %{})
        |> Map.put("kind", Agents.builder_kind())
        |> Map.put("active_agent_id", next_active_agent_id)
        |> Map.put("draft_state", draft_patch || %{})

      {:ok, updated_session} = Agents.update_builder_session(session, %{metadata: metadata})

      {:ok,
       %{
         conversationId: updated_session.id,
         activeAgentId: next_active_agent_id,
         reply: reply,
         suggestions: default_suggestions(),
         draftPatch: draft_patch || %{},
         agent: if(agent, do: Agents.agent_payload(agent), else: nil)
       }}
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
         draftPatch: (session.metadata && session.metadata["draft_state"]) || %{},
         agent: if(active_agent, do: Agents.agent_payload(active_agent), else: nil),
         suggestions: default_suggestions()
       }}
    end
  end

  defp handle_command(user_id, message, active_agent_id) do
    [command | rest] =
      message
      |> String.trim()
      |> String.split(~r/\s+/, trim: true)

    args = Enum.join(rest, " ")

    case String.downcase(command) do
      "/help" ->
        {help_text(), nil, %{}, active_agent_id}

      "/agents" ->
        agents = Agents.list_agents(user_id)

        reply =
          if agents == [] do
            "No agents yet. Use /newagent <name> to create one."
          else
            "Your agents:\n" <>
              Enum.map_join(agents, "\n", fn agent ->
                payload = Agents.agent_payload(agent)
                "- #{payload.displayName} (@#{payload.username}) [#{payload.status}]"
              end)
          end

        {reply, nil, %{}, active_agent_id}

      "/newagent" ->
        display_name = if String.trim(args) == "", do: "New Agent", else: args

        case Agents.create_agent(user_id, %{"display_name" => display_name}) do
          {:ok, agent, _secret} ->
            payload = Agents.agent_payload(agent)
            reply = "Created #{payload.displayName} as @#{payload.username}. Use /prompt or send a plain-language description next."
            {reply, agent, payload, agent.id}

          {:error, :quota_exceeded} ->
            {"Agent limit reached for your current plan.", nil, %{}, active_agent_id}

          {:error, reason} ->
            {"Could not create agent: #{inspect(reason)}", nil, %{}, active_agent_id}
        end

      "/select" ->
        normalized = String.trim(args)
        agent =
          Agents.get_agent(normalized, user_id) ||
            Agents.get_agent_by_username(normalized)

        if agent && agent.owner_user_id == user_id do
          payload = Agents.agent_payload(agent)
          {"Selected #{payload.displayName} (@#{payload.username}).", agent, payload, agent.id}
        else
          {"Agent not found.", nil, %{}, active_agent_id}
        end

      "/name" ->
        with %{} = agent <- require_active_agent(user_id, active_agent_id),
             {:ok, updated} <- Agents.update_agent(agent, %{"display_name" => args}, user_id) do
          payload = Agents.agent_payload(updated)
          {"Updated name to #{payload.displayName}.", updated, %{displayName: payload.displayName}, updated.id}
        else
          nil -> {"Select an agent first with /newagent or /select.", nil, %{}, active_agent_id}
          {:error, reason} -> {"Could not update name: #{inspect(reason)}", nil, %{}, active_agent_id}
        end

      "/username" ->
        with %{} = agent <- require_active_agent(user_id, active_agent_id),
             {:ok, updated} <- Agents.update_agent(agent, %{"username" => args}, user_id) do
          payload = Agents.agent_payload(updated)
          {"Updated username to @#{payload.username}.", updated, %{username: payload.username}, updated.id}
        else
          nil -> {"Select an agent first with /newagent or /select.", nil, %{}, active_agent_id}
          {:error, reason} -> {"Could not update username: #{inspect(reason)}", nil, %{}, active_agent_id}
        end

      "/prompt" ->
        with %{} = agent <- require_active_agent(user_id, active_agent_id),
             {:ok, updated} <- Agents.update_agent(agent, %{"system_prompt" => args}, user_id) do
          {"Updated the system prompt.", updated, %{systemPrompt: updated.system_prompt}, updated.id}
        else
          nil -> {"Select an agent first with /newagent or /select.", nil, %{}, active_agent_id}
          {:error, reason} -> {"Could not update prompt: #{inspect(reason)}", nil, %{}, active_agent_id}
        end

      "/persona" ->
        with %{} = agent <- require_active_agent(user_id, active_agent_id),
             {:ok, updated} <- Agents.update_agent(agent, %{"persona" => args}, user_id) do
          {"Updated the persona.", updated, %{persona: updated.persona}, updated.id}
        else
          nil -> {"Select an agent first with /newagent or /select.", nil, %{}, active_agent_id}
          {:error, reason} -> {"Could not update persona: #{inspect(reason)}", nil, %{}, active_agent_id}
        end

      "/tools" ->
        tools =
          case String.downcase(String.trim(args)) do
            "all" -> Agents.default_enabled_tools()
            _ -> String.split(args, ",", trim: true)
          end

        with %{} = agent <- require_active_agent(user_id, active_agent_id),
             {:ok, updated} <- Agents.update_agent(agent, %{"enabled_tools" => tools}, user_id) do
          {"Updated enabled tools.", updated, %{enabledTools: updated.enabled_tools}, updated.id}
        else
          nil -> {"Select an agent first with /newagent or /select.", nil, %{}, active_agent_id}
          {:error, reason} -> {"Could not update tools: #{inspect(reason)}", nil, %{}, active_agent_id}
        end

      "/voice" ->
        {modes, voice_profile} = parse_voice_args(args)

        with %{} = agent <- require_active_agent(user_id, active_agent_id),
             {:ok, updated} <-
               Agents.update_agent(
                 agent,
                 %{"output_modes" => modes, "voice_profile" => voice_profile},
                 user_id
               ) do
          {
            "Updated voice mode.",
            updated,
            %{outputModes: updated.output_modes, voiceProfile: updated.voice_profile},
            updated.id
          }
        else
          nil -> {"Select an agent first with /newagent or /select.", nil, %{}, active_agent_id}
          {:error, reason} -> {"Could not update voice mode: #{inspect(reason)}", nil, %{}, active_agent_id}
        end

      "/webhook" ->
        callback_url =
          case String.downcase(String.trim(args)) do
            "off" -> nil
            _ -> args
          end

        with %{} = agent <- require_active_agent(user_id, active_agent_id),
             {:ok, updated} <- Agents.update_agent(agent, %{"callback_url" => callback_url}, user_id) do
          {"Updated callback URL.", updated, %{callbackUrl: updated.callback_url}, updated.id}
        else
          nil -> {"Select an agent first with /newagent or /select.", nil, %{}, active_agent_id}
          {:error, reason} -> {"Could not update webhook: #{inspect(reason)}", nil, %{}, active_agent_id}
        end

      "/publish" ->
        with %{} = agent <- require_active_agent(user_id, active_agent_id),
             {:ok, updated} <- Agents.publish_agent(agent, user_id) do
          {"Published @#{updated.agent_user.username}.", updated, %{status: updated.status}, updated.id}
        else
          nil -> {"Select an agent first with /newagent or /select.", nil, %{}, active_agent_id}
          {:error, reason} -> {"Could not publish agent: #{inspect(reason)}", nil, %{}, active_agent_id}
        end

      "/disable" ->
        requested = if String.downcase(String.trim(args)) in ["off", "false"], do: "published", else: "disabled"

        with %{} = agent <- require_active_agent(user_id, active_agent_id),
             {:ok, updated} <- Agents.update_agent(agent, %{"status" => requested}, user_id) do
          {"Updated agent status to #{updated.status}.", updated, %{status: updated.status}, updated.id}
        else
          nil -> {"Select an agent first with /newagent or /select.", nil, %{}, active_agent_id}
          {:error, reason} -> {"Could not update status: #{inspect(reason)}", nil, %{}, active_agent_id}
        end

      "/secret" ->
        with %{} = agent <- require_active_agent(user_id, active_agent_id),
             {:ok, updated, secret} <- Agents.rotate_secret(agent, user_id) do
          {"Rotated secret. New secret: #{secret}", updated, %{secretHint: updated.secret_hint}, updated.id}
        else
          nil -> {"Select an agent first with /newagent or /select.", nil, %{}, active_agent_id}
          {:error, reason} -> {"Could not rotate secret: #{inspect(reason)}", nil, %{}, active_agent_id}
        end

      _ ->
        {"Unknown command. Use /help for supported commands.", nil, %{}, active_agent_id}
    end
  end

  defp handle_freeform(user_id, message, active_agent_id) do
    agent =
      require_active_agent(user_id, active_agent_id) ||
        case Agents.create_agent(user_id, %{"display_name" => "New Agent"}) do
          {:ok, created, _secret} -> created
          _ -> nil
        end

    if agent do
      enabled_tools = agent.enabled_tools || Agents.default_enabled_tools()

      generated_prompt =
        case GroupAgent.generate_system_prompt(message, enabled_tools) do
          {:ok, prompt} -> prompt
          _ -> message
        end

      case Agents.update_agent(agent, %{"system_prompt" => generated_prompt, "persona" => message}, user_id) do
        {:ok, updated} ->
          payload = Agents.agent_payload(updated)
          reply = "Updated #{payload.displayName}. I turned your description into the agent prompt."
          {reply, updated, %{systemPrompt: updated.system_prompt, persona: updated.persona}, updated.id}

        {:error, reason} ->
          {"Could not update agent: #{inspect(reason)}", nil, %{}, active_agent_id}
      end
    else
      {"Could not create a draft agent.", nil, %{}, active_agent_id}
    end
  end

  defp require_active_agent(user_id, active_agent_id) when is_binary(active_agent_id) do
    Agents.get_agent(active_agent_id, user_id)
  end

  defp require_active_agent(_user_id, _active_agent_id), do: nil

  defp default_suggestions do
    [
      "/newagent Sales Assistant",
      "/agents",
      "/prompt You are a concise travel planner",
      "/help"
    ]
  end

  defp parse_voice_args(args) do
    tokens =
      args
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map(&String.downcase/1)

    case tokens do
      ["off" | _] ->
        {["text"], nil}

      ["on", profile | _] ->
        {["text", "voice"], profile}

      ["on"] ->
        {["text", "voice"], "alloy"}

      [profile | _] ->
        {["text", "voice"], profile}

      [] ->
        {["text", "voice"], "alloy"}
    end
  end

  defp help_text do
    """
    Commands:
    /newagent <name>
    /agents
    /select <agent_id|@username>
    /name <display name>
    /username <username>
    /prompt <system prompt>
    /persona <persona>
    /tools <comma list|all>
    /voice on|off [profile]
    /webhook <url|off>
    /publish
    /disable on|off
    /secret rotate
    """
    |> String.trim()
  end
end
