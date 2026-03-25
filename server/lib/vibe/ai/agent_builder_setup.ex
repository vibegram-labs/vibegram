defmodule Vibe.AI.AgentBuilderSetup do
  @moduledoc false

  require Logger

  alias Vibe.AgentConversation
  alias Vibe.Agents
  alias Vibe.AI.AgentRuntime
  alias Vibe.AI.GroupAgent
  alias Vibe.AI.ToolRegistry

  @orchestrator_model "claude-sonnet-4-20250514"
  @worker_model "claude-haiku-4-5-20251001"
  @structured_worker_tool "submit_result"
  @max_recent_messages 8
  @progress_worker_keys ~w[
    setup_orchestrator
    clarifier
    question_composer
    prompt_builder
    capability_planner
    validator
    publisher
  ]
  @field_keys ~w[
    audience
    autonomy_mode
    blocked_actions
    business_summary
    business_type
    default_destination_chat_id
    display_name
    do_list
    dont_list
    enabled_tools
    escalation_policy
    expected_behaviors
    language
    output_modes
    persona
    primary_jobs
    sample_prompts
    success_criteria
    suggested_integrations
    system_prompt
    tone
    username
    welcome_message
  ]
  @identity_question_fields ~w[
    display_name
    username
    persona
    tone
    language
    welcome_message
    system_prompt
  ]
  @question_priority %{
    "business_summary" => 120,
    "primary_jobs" => 115,
    "enabled_tools" => 110,
    "suggested_integrations" => 105,
    "do_list" => 100,
    "success_criteria" => 96,
    "audience" => 92,
    "blocked_actions" => 90,
    "escalation_policy" => 88,
    "autonomy_mode" => 84,
    "default_destination_chat_id" => 80,
    "output_modes" => 74,
    "business_type" => 70,
    "display_name" => 22,
    "username" => 18,
    "persona" => 14,
    "tone" => 10,
    "language" => 8,
    "welcome_message" => 6,
    "system_prompt" => 4
  }
  @status_values ~w[idle discovering clarifying assembling review_ready draft_created]
  @legacy_keywords [
    "invoke",
    "integration",
    "webhook",
    "callback",
    "rotate secret",
    "secret",
    "publish",
    "disable",
    "enable",
    "chat id",
    "chatid",
    "vibechatid",
    "invoke url",
    "events url"
  ]
  @setup_keywords [
    "i need agent",
    "need an agent",
    "need agent",
    "create agent",
    "build agent",
    "set up agent",
    "setup agent",
    "make an agent",
    "make agent",
    "agent for my",
    "agent for our",
    "draft an agent"
  ]
  @create_draft_request_id "setup:create_draft"

  def handles?(input, metadata, active_agent_id) do
    normalized_metadata = normalize_metadata(metadata, active_agent_id)
    message = normalize_optional_string(input[:message])
    ui_response = normalize_ui_response(input[:ui_response])
    spec = Map.get(normalized_metadata, "setup_spec") || %{}
    status = normalize_optional_string(get_in_string(spec, ["status"]))
    pending_ui_request = normalized_metadata["pending_ui_request"]

    cond do
      is_map(ui_response) ->
        true

      is_map(pending_ui_request) and is_binary(message) ->
        true

      status in ["discovering", "clarifying", "assembling"] and is_binary(message) ->
        true

      status in @status_values and is_binary(message) and not explicit_legacy_intent?(message) ->
        true

      status in @status_values and is_binary(message) ->
        false

      is_binary(message) and looks_like_setup_request?(message) ->
        true

      true ->
        false
    end
  end

  def session_fields(metadata) do
    normalized_metadata = normalize_metadata(metadata, nil)

    %{
      setupState: normalize_setup_state_payload(normalized_metadata["setup_state"]),
      pendingUiRequest: normalize_public_ui_request(normalized_metadata["pending_ui_request"]),
      reviewSections: normalize_review_sections(normalized_metadata["review_sections"]),
      activity: normalize_activity(normalized_metadata["activity"])
    }
  end

  def handle(user_id, session, input, active_agent_id, callback \\ nil) do
    metadata = normalize_metadata(session.metadata || %{}, active_agent_id)
    active_agent_id = metadata["active_agent_id"]
    active_agent = if is_binary(active_agent_id), do: Agents.get_agent(active_agent_id, user_id), else: nil

    {metadata, active_agent} =
      maybe_reset_for_new_setup(metadata, active_agent, normalize_optional_string(input[:message]))

    spec = normalize_setup_spec(metadata["setup_spec"], active_agent)
    pending_ui_request = metadata["pending_ui_request"]
    review_sections = normalize_review_sections(metadata["review_sections"])
    ui_response = normalize_ui_response(input[:ui_response])
    message = normalize_optional_string(input[:message])

    case classify_input(message, ui_response, pending_ui_request, review_sections) do
      {:create_draft, _ui_payload} ->
        create_or_update_draft(
          user_id,
          session,
          spec,
          metadata,
          active_agent,
          callback
        )

      input_classification ->
        {spec, pending_ui_request, active_agent, active_agent_id, user_display} =
          case input_classification do
            {:edit_section, request, answers} ->
              next_spec = apply_answers_to_spec(spec, request["fields"] || [], answers)
              {next_spec, nil, active_agent, active_agent_id, summarize_ui_answers(request, answers)}

            {:ui_answers, request, answers} ->
              next_spec = apply_answers_to_spec(spec, request["fields"] || [], answers)
              {next_spec, nil, active_agent, active_agent_id, summarize_ui_answers(request, answers)}

            {:plain_text_answer, request, answers} ->
              next_spec = apply_answers_to_spec(spec, request["fields"] || [], answers)
              {next_spec, nil, active_agent, active_agent_id, message}

            {:message, user_message} ->
              {spec, pending_ui_request, active_agent, active_agent_id, user_message}
          end

        progress_input =
          normalize_optional_string(message) ||
            normalize_optional_string(user_display) ||
            get_in_string(spec, ["intent", "businessSummary"]) ||
            "Set up the agent"

        activity =
          build_dynamic_activity_plan(
            spec,
            progress_input,
            active_agent,
            session.messages || []
          )

        activity = start_progress_step(activity, "setup_orchestrator")
        emit_progress_state(callback, spec, "discovering", activity)

        {spec, activity} =
          case message do
            value when is_binary(value) ->
              next_spec = orchestrate_spec(spec, value, active_agent, session.messages || [])

              {
                next_spec,
                complete_progress_step(
                  activity,
                  "setup_orchestrator",
                  summarize_orchestration_progress(next_spec)
                )
              }

            _ ->
              {
                spec,
                complete_progress_step(
                  activity,
                  "setup_orchestrator",
                  "Applied the latest structured answers to the setup."
                )
              }
          end

        emit_progress_state(callback, spec, "discovering", activity)

        activity = start_progress_step(activity, "clarifier")
        emit_progress_state(callback, spec, "discovering", activity)
        clarifier_result = clarify_spec(spec)
        activity =
          complete_progress_step(
            activity,
            "clarifier",
            summarize_clarifier_progress(clarifier_result)
          )
        emit_progress_state(
          callback,
          spec,
          if(clarifier_result["shouldAskUser"], do: "clarifying", else: "assembling"),
          activity
        )

        if clarifier_result["shouldAskUser"] do
          activity = start_progress_step(activity, "question_composer")
          emit_progress_state(callback, spec, "clarifying", activity)

          ui_request =
            compose_question_request(
              spec,
              clarifier_result,
              pending_ui_request,
              active_agent,
              callback
            )

          reply = nil

          next_spec = put_string_path(spec, ["status"], "clarifying")
          setup_state = build_setup_state(next_spec, "clarifying")
          activity =
            activity
            |> complete_progress_step(
              "question_composer",
              summarize_question_progress(ui_request)
            )
            |> mark_root_progress(
              "attention",
              "Waiting on the next answers before the draft can continue."
            )
          emit_progress_state(callback, next_spec, "clarifying", activity)
          draft_patch = build_virtual_draft_patch(next_spec, active_agent)

          persist_guided_result(
            user_id,
            session,
            %{
              metadata: metadata,
              active_agent_id: active_agent_id,
              active_agent: active_agent,
              reply: reply,
              latest_secret: metadata["latest_secret"],
              setup_spec: next_spec,
              setup_state: setup_state,
              pending_ui_request: ui_request,
              review_sections: [],
              activity: activity,
              draft_patch: draft_patch,
              user_display: user_display
            }
          )
        else
          {prompt_result, capability_result, activity} =
            run_configuration_workers(spec, activity, callback)

          built_spec =
            spec
            |> merge_prompt_assets(prompt_result)
            |> merge_capability_assets(capability_result)
            |> put_string_path(["status"], "assembling")

          draft_patch = build_virtual_draft_patch(built_spec, active_agent)
          emit(callback, :draft_patch, %{draftPatch: draft_patch})

          activity = start_progress_step(activity, "validator")
          emit_progress_state(callback, built_spec, "assembling", activity)
          validation = validate_spec(built_spec)
          activity =
            complete_progress_step(
              activity,
              "validator",
              summarize_validator_progress(validation)
            )
          emit_progress_state(callback, built_spec, "assembling", activity)

          final_spec =
            built_spec
            |> put_string_path(["publishing", "isReady"], validation["isReady"] == true)
            |> put_string_path(["publishing", "missingCriticalFields"], normalize_string_list(validation["missingCriticalFields"]))
            |> put_string_path(["publishing", "confidence"], normalize_confidence(validation["confidence"]))
            |> put_string_path(["status"], "review_ready")

          sections = build_review_sections(final_spec, validation)
          setup_state = build_setup_state(final_spec, "review_ready")
          activity =
            activity
            |> mark_root_progress(
              "attention",
              "The draft is assembled. Review the generated sections before you create it."
            )
          emit(callback, :review_ready, %{reviewSections: sections, setupState: setup_state, activity: activity, draftPatch: draft_patch})

          reply =
            normalize_optional_string(validation["overview"]) ||
              "I prepared a publish-ready draft. Review the sections and create the draft when it looks right."

          persist_guided_result(
            user_id,
            session,
            %{
              metadata: metadata,
              active_agent_id: active_agent_id,
              active_agent: active_agent,
              reply: reply,
              latest_secret: metadata["latest_secret"],
              setup_spec: final_spec,
              setup_state: setup_state,
              pending_ui_request: nil,
              review_sections: sections,
              activity: activity,
              draft_patch: draft_patch,
              user_display: user_display
            }
          )
        end
    end
  end

  defp create_or_update_draft(user_id, session, spec, metadata, active_agent, callback) do
    activity =
      metadata["activity"]
      |> normalize_activity()
      |> ensure_publisher_activity(spec)
      |> start_progress_step("publisher")

    emit_progress_state(callback, spec, "review_ready", activity)

    draft_attrs = build_draft_attrs(spec)

    result =
      case active_agent do
        %{} = agent ->
          case Agents.update_agent(agent, draft_attrs, user_id) do
            {:ok, updated} -> {:ok, updated, metadata["latest_secret"]}
            error -> error
          end

        nil ->
          Agents.create_agent(user_id, draft_attrs)
      end

    case result do
      {:ok, agent, latest_secret} ->
        final_spec = put_string_path(spec, ["status"], "draft_created")
        sections = build_review_sections(final_spec, validate_spec(final_spec))
        setup_state = build_setup_state(final_spec, "draft_created")
        activity =
          activity
          |> complete_progress_step(
            "publisher",
            "Created the draft and synced the generated agent settings."
          )
          |> mark_root_progress("completed", "Draft created and ready for testing or publish.")
        emit_progress_state(callback, final_spec, "draft_created", activity)
        draft_patch = Agents.agent_payload(agent)

        persist_guided_result(
          user_id,
          session,
          %{
            metadata: metadata,
            active_agent_id: agent.id,
            active_agent: agent,
            reply: build_draft_created_reply(agent, latest_secret),
            latest_secret: latest_secret,
            setup_spec: final_spec,
            setup_state: setup_state,
            pending_ui_request: nil,
            review_sections: sections,
            activity: activity,
            draft_patch: draft_patch,
            user_display: "Create draft"
          }
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_guided_result(_user_id, session, attrs) do
    metadata =
      attrs.metadata
      |> normalize_metadata(attrs.active_agent_id)
      |> Map.put("setup_spec", attrs.setup_spec)
      |> Map.put("setup_state", attrs.setup_state)
      |> Map.put("pending_ui_request", attrs.pending_ui_request)
      |> Map.put("review_sections", attrs.review_sections)
      |> Map.put("activity", attrs.activity)
      |> Map.put("draft_state", attrs.draft_patch || %{})
      |> Map.put("latest_secret", attrs.latest_secret)
      |> Map.put("active_agent_id", attrs.active_agent_id)

    maybe_add_message(session.id, "user", attrs.user_display)
    maybe_add_message(session.id, "assistant", attrs.reply)

    {:ok, updated_session} = Agents.update_builder_session(session, %{metadata: metadata})

    agent_payload =
      case attrs.active_agent do
        %{} = agent -> Agents.agent_payload(agent)
        _ -> nil
      end

    {:ok,
     %{
       conversationId: updated_session.id,
       activeAgentId: attrs.active_agent_id,
       reply: attrs.reply,
       draftPatch: attrs.draft_patch || %{},
       agent: agent_payload,
       latestSecret: attrs.latest_secret,
       setupState: attrs.setup_state,
       pendingUiRequest: normalize_public_ui_request(attrs.pending_ui_request),
       reviewSections: normalize_review_sections(attrs.review_sections),
       activity: normalize_activity(attrs.activity)
     }}
  end

  defp maybe_add_message(_conversation_id, _role, nil), do: :ok

  defp maybe_add_message(conversation_id, role, content) when is_binary(content) do
    trimmed = String.trim(content)

    if trimmed == "" do
      :ok
    else
      AgentConversation.add_message(conversation_id, %{
        "role" => role,
        "content" => trimmed
      })
    end
  end

  defp classify_input(message, ui_response, pending_ui_request, review_sections) do
    cond do
      is_map(ui_response) and normalize_optional_string(ui_response["requestId"]) == @create_draft_request_id ->
        {:create_draft, ui_response}

      is_map(ui_response) ->
        request_id = normalize_optional_string(ui_response["requestId"])
        answers = normalize_answer_map(ui_response["answers"])

        cond do
          request = find_request_by_id(review_sections, request_id) ->
            {:edit_section, request, answers}

          is_map(pending_ui_request) and pending_ui_request["id"] == request_id ->
            {:ui_answers, pending_ui_request, answers}

          true ->
            {:message, normalize_optional_string(message) || ""}
        end

      is_binary(message) and is_map(pending_ui_request) and compatible_plain_text_request?(pending_ui_request) ->
        field = List.first(pending_ui_request["fields"] || [])
        {:plain_text_answer, pending_ui_request, %{field["key"] => message}}

      true ->
        {:message, normalize_optional_string(message) || ""}
    end
  end

  defp compatible_plain_text_request?(%{"fields" => [field]}) do
    field["type"] in ["text", "long_text", "single_select"]
  end

  defp compatible_plain_text_request?(_request), do: false

  defp find_request_by_id(review_sections, request_id) do
    Enum.find(review_sections || [], fn section -> section["requestId"] == request_id end)
  end

  defp maybe_reset_for_new_setup(metadata, active_agent, message) do
    if is_binary(message) and force_new_setup?(message) do
      {
        metadata
        |> Map.put("active_agent_id", nil)
        |> Map.put("draft_state", %{})
        |> Map.put("pending_ui_request", nil)
        |> Map.put("review_sections", [])
        |> Map.put("setup_spec", nil)
        |> Map.put("setup_state", nil)
        |> Map.put("activity", []),
        nil
      }
    else
      {metadata, active_agent}
    end
  end

  defp emit_progress_state(callback, spec, status, activity) do
    emit(callback, :state, %{
      setupState: build_setup_state(spec, status),
      activity: normalize_activity(activity)
    })
  end

  defp build_dynamic_activity_plan(spec, latest_input, active_agent, messages) do
    schema = %{
      type: "object",
      properties: %{
        goalTitle: string_schema(true),
        goalDetail: string_schema(true),
        steps: %{
          type: "array",
          items: %{
            type: "object",
            properties: %{
              workerKey: string_schema(),
              title: string_schema(),
              agentLabel: string_schema(true),
              detail: string_schema(true),
              prompt: string_schema(true)
            }
          }
        }
      }
    }

    payload = %{
      latest_input: latest_input,
      current_spec: spec,
      active_agent: summarize_active_agent(active_agent),
      recent_messages: recent_message_excerpt(messages),
      allowed_worker_keys: @progress_worker_keys
    }

    case call_structured_worker(
           @worker_model,
           """
           You are ExecutionPlanner for Vibe's guided agent builder.
           Create a short live progress tree for the hidden setup workers.
           Use only worker keys from allowed_worker_keys.
           Titles and details must be user-facing and concise.
           The prompt field must be a sanitized one-line summary of what that worker is trying to figure out.
           Do not reveal secrets, raw chain-of-thought, or internal safety rules.
           """,
           Jason.encode!(payload),
           schema
         ) do
      {:ok, result} ->
        normalize_dynamic_activity_plan(result, spec, latest_input)

      {:error, reason} ->
        Logger.warning("[AgentBuilderSetup] Execution planner fallback: #{inspect(reason)}")
        fallback_dynamic_activity_plan(spec, latest_input)
    end
  end

  defp normalize_dynamic_activity_plan(result, spec, latest_input) do
    normalized = normalize_map(result)

    goal_title =
      normalize_optional_string(normalized["goalTitle"]) ||
        dynamic_goal_title(spec, latest_input)

    goal_detail =
      normalize_optional_string(normalized["goalDetail"]) ||
        get_in_string(spec, ["intent", "businessSummary"]) ||
        normalize_optional_string(latest_input)

    root = %{
      "id" => "goal",
      "title" => goal_title,
      "status" => "in_progress",
      "detail" => goal_detail,
      "depth" => 0
    }

    step_maps =
      normalized["steps"]
      |> List.wrap()
      |> Enum.map(&normalize_map/1)
      |> Enum.reduce([], fn step, acc ->
        worker_key = normalize_optional_string(step["workerKey"])

        if worker_key in @progress_worker_keys and Enum.all?(acc, &(&1["id"] != worker_key)) do
          acc ++
            [
              %{
                "id" => worker_key,
                "title" => normalize_optional_string(step["title"]) || default_worker_title(worker_key),
                "status" => "pending",
                "detail" => normalize_optional_string(step["detail"]),
                "agentLabel" => normalize_optional_string(step["agentLabel"]) || default_agent_label(worker_key),
                "prompt" => normalize_optional_string(step["prompt"]),
                "parentId" => "goal",
                "depth" => 1
              }
            ]
        else
          acc
        end
      end)

    required_steps =
      @progress_worker_keys
      |> Enum.reject(fn worker_key -> Enum.any?(step_maps, &(&1["id"] == worker_key)) end)
      |> Enum.map(fn worker_key ->
        %{
          "id" => worker_key,
          "title" => default_worker_title(worker_key),
          "status" => "pending",
          "detail" => nil,
          "agentLabel" => default_agent_label(worker_key),
          "prompt" => nil,
          "parentId" => "goal",
          "depth" => 1
        }
      end)

    [root | step_maps ++ required_steps]
  end

  defp fallback_dynamic_activity_plan(spec, latest_input) do
    [
      %{
        "id" => "goal",
        "title" => dynamic_goal_title(spec, latest_input),
        "status" => "in_progress",
        "detail" =>
          get_in_string(spec, ["intent", "businessSummary"]) ||
            normalize_optional_string(latest_input),
        "depth" => 0
      },
      %{
        "id" => "setup_orchestrator",
        "title" => "Understand the agent setup request",
        "status" => "pending",
        "agentLabel" => "Setup Orchestrator",
        "prompt" => "Interpret the request and update the hidden setup spec.",
        "parentId" => "goal",
        "depth" => 1
      },
      %{
        "id" => "clarifier",
        "title" => "Decide whether more answers are required",
        "status" => "pending",
        "agentLabel" => "Clarifier",
        "prompt" => "Ask only blocking questions that change behavior, tools, or safety.",
        "parentId" => "goal",
        "depth" => 1
      },
      %{
        "id" => "question_composer",
        "title" => "Compose the next setup question",
        "status" => "pending",
        "agentLabel" => "Question Composer",
        "prompt" => "Turn clarification goals into a short setup sheet.",
        "parentId" => "goal",
        "depth" => 1
      },
      %{
        "id" => "capability_planner",
        "title" => "Choose tools and automation limits",
        "status" => "pending",
        "agentLabel" => "Capability Planner",
        "prompt" => "Pick the smallest useful toolset and safe autonomy mode.",
        "parentId" => "goal",
        "depth" => 1
      },
      %{
        "id" => "prompt_builder",
        "title" => "Write the system prompt and welcome message",
        "status" => "pending",
        "agentLabel" => "Prompt Builder",
        "prompt" => "Draft the production-ready prompt and a short welcome message.",
        "parentId" => "goal",
        "depth" => 1
      },
      %{
        "id" => "validator",
        "title" => "Review the assembled setup",
        "status" => "pending",
        "agentLabel" => "Validator",
        "prompt" => "Check readiness, missing fields, and unsafe autonomy.",
        "parentId" => "goal",
        "depth" => 1
      },
      %{
        "id" => "publisher",
        "title" => "Create or update the draft",
        "status" => "pending",
        "agentLabel" => "Publisher",
        "prompt" => "Persist the final setup into the draft agent.",
        "parentId" => "goal",
        "depth" => 1
      }
    ]
  end

  defp run_configuration_workers(spec, activity, callback) do
    ordered_workers = ordered_worker_keys(activity, ["capability_planner", "prompt_builder"])

    Enum.reduce(ordered_workers, {%{}, %{}, activity}, fn worker_key, {prompt_result, capability_result, current_activity} ->
      next_activity = start_progress_step(current_activity, worker_key)
      emit_progress_state(callback, spec, "assembling", next_activity)

      case worker_key do
        "prompt_builder" ->
          result = build_prompt_assets(spec)
          finished_activity =
            complete_progress_step(
              next_activity,
              worker_key,
              summarize_prompt_progress(result)
            )
          emit_progress_state(callback, spec, "assembling", finished_activity)

          {
            result,
            capability_result,
            finished_activity
          }

        "capability_planner" ->
          result = build_capability_assets(spec)
          finished_activity =
            complete_progress_step(
              next_activity,
              worker_key,
              summarize_capability_progress(result)
            )
          emit_progress_state(callback, spec, "assembling", finished_activity)

          {
            prompt_result,
            result,
            finished_activity
          }

        _ ->
          {prompt_result, capability_result, next_activity}
      end
    end)
  end

  defp ordered_worker_keys(activity, defaults) do
    activity
    |> normalize_activity()
    |> Enum.filter(&(&1.id in defaults))
    |> Enum.map(& &1.id)
    |> case do
      [] -> defaults
      items -> items ++ Enum.reject(defaults, &(&1 in items))
    end
  end

  defp start_progress_step(activity, worker_key) do
    activity
    |> normalize_activity()
    |> Enum.map(fn item ->
      cond do
        item.id == worker_key ->
          Map.put(item, :status, "in_progress")

        true ->
          item
      end
    end)
    |> mark_root_progress("in_progress", nil)
  end

  defp complete_progress_step(activity, worker_key, detail) do
    activity
    |> normalize_activity()
    |> Enum.map(fn item ->
      cond do
        item.id == worker_key ->
          item
          |> Map.put(:status, "completed")
          |> maybe_put_activity_detail(detail)

        true ->
          item
      end
    end)
  end

  defp ensure_publisher_activity(activity, spec) do
    normalized = normalize_activity(activity)

    if Enum.any?(normalized, &(&1.id == "publisher")) do
      normalized
    else
      normalized ++
        [
          %{
            id: "publisher",
            title: default_worker_title("publisher"),
            status: "pending",
            detail: get_in_string(spec, ["intent", "businessSummary"]),
            agentLabel: default_agent_label("publisher"),
            prompt: "Persist the generated setup into the agent draft.",
            parentId: "goal",
            depth: 1
          }
        ]
    end
  end

  defp mark_root_progress(activity, status, detail) do
    activity
    |> normalize_activity()
    |> Enum.map(fn item ->
      if item.id == "goal" do
        item
        |> Map.put(:status, status)
        |> maybe_put_activity_detail(detail)
      else
        item
      end
    end)
  end

  defp maybe_put_activity_detail(item, detail) when is_binary(detail) do
    Map.put(item, :detail, detail)
  end

  defp maybe_put_activity_detail(item, _detail), do: item

  defp dynamic_goal_title(spec, latest_input) do
    get_in_string(spec, ["intent", "businessSummary"]) ||
      normalize_optional_string(latest_input) ||
      "Set up the agent"
  end

  defp default_worker_title("setup_orchestrator"), do: "Understand the setup request"
  defp default_worker_title("clarifier"), do: "Decide whether more answers are needed"
  defp default_worker_title("question_composer"), do: "Compose the next setup question"
  defp default_worker_title("prompt_builder"), do: "Write the system prompt"
  defp default_worker_title("capability_planner"), do: "Choose tools and autonomy"
  defp default_worker_title("validator"), do: "Review the assembled setup"
  defp default_worker_title("publisher"), do: "Create or update the draft"
  defp default_worker_title(_worker_key), do: "Process the setup"

  defp default_agent_label("setup_orchestrator"), do: "Setup Orchestrator"
  defp default_agent_label("clarifier"), do: "Clarifier"
  defp default_agent_label("question_composer"), do: "Question Composer"
  defp default_agent_label("prompt_builder"), do: "Prompt Builder"
  defp default_agent_label("capability_planner"), do: "Capability Planner"
  defp default_agent_label("validator"), do: "Validator"
  defp default_agent_label("publisher"), do: "Publisher"
  defp default_agent_label(_worker_key), do: "Worker"

  defp summarize_orchestration_progress(spec) do
    jobs = get_in_string(spec, ["intent", "primaryJobs"]) || []
    business = get_in_string(spec, ["intent", "businessSummary"])

    cond do
      is_list(jobs) and jobs != [] -> "Focused the setup around #{Enum.join(Enum.take(jobs, 3), ", ")}."
      is_binary(business) and business != "" -> business
      true -> "Updated the setup direction from the latest request."
    end
  end

  defp summarize_clarifier_progress(%{"shouldAskUser" => true, "missingCriticalFields" => fields}) do
    missing = normalize_string_list(fields)
    if missing == [], do: "Needs a few blocking answers before continuing.", else: "Still needs #{Enum.join(missing, ", ")}."
  end

  defp summarize_clarifier_progress(_result) do
    "No blocking questions are needed. The draft can continue."
  end

  defp summarize_question_progress(nil), do: "Prepared the next setup question."
  defp summarize_question_progress(request) do
    normalize_optional_string(request["title"]) ||
      normalize_optional_string(request[:title]) ||
      "Prepared the next setup question."
  end

  defp summarize_prompt_progress(result) do
    cond do
      is_binary(result["welcomeMessage"]) and result["welcomeMessage"] != "" ->
        "Drafted the system prompt and welcome message."

      is_binary(result["systemPrompt"]) and result["systemPrompt"] != "" ->
        "Drafted the system prompt."

      true ->
        "Refined the prompt instructions."
    end
  end

  defp summarize_capability_progress(result) do
    tools = normalize_tool_list(result["enabledTools"])
    modes = normalize_output_modes(result["outputModes"])

    cond do
      tools != [] and modes != [] ->
        "Selected #{Enum.join(Enum.take(tools, 3), ", ")} with #{Enum.join(modes, ", ")} outputs."

      tools != [] ->
        "Selected #{Enum.join(Enum.take(tools, 3), ", ")}."

      true ->
        "Updated the tool and autonomy plan."
    end
  end

  defp summarize_validator_progress(validation) do
    cond do
      validation["isReady"] == true ->
        "The setup is ready for review."

      true ->
        missing = normalize_string_list(validation["missingCriticalFields"])
        if missing == [], do: "The setup still needs review.", else: "Still missing #{Enum.join(missing, ", ")}."
    end
  end

  defp orchestrate_spec(spec, message, active_agent, messages) do
    payload = %{
      current_spec: spec,
      active_agent: summarize_active_agent(active_agent),
      recent_messages: recent_message_excerpt(messages),
      latest_input: message
    }

    schema = %{
      type: "object",
      properties: %{
        intent: object_schema(%{
          rawRequest: string_schema(),
          businessSummary: string_schema(),
          businessType: string_schema(true),
          audience: string_array_schema(),
          primaryJobs: string_array_schema(),
          successCriteria: string_array_schema()
        }),
        identity: object_schema(%{
          displayName: string_schema(true),
          username: string_schema(true),
          persona: string_schema(true),
          tone: string_schema(true),
          language: string_schema(true)
        }),
        behavior: object_schema(%{
          doList: string_array_schema(),
          dontList: string_array_schema(),
          escalationPolicy: string_schema(true)
        }),
        confidence: %{type: "number"},
        assistantReply: string_schema(true)
      }
    }

    result =
      call_structured_worker(
        @orchestrator_model,
        """
        You are SetupOrchestrator for Vibe's guided agent builder.
        Update the agent setup spec from the user's latest freeform input.
        Preserve existing decisions unless the latest input clearly changes them.
        Keep fields concise and practical.
        Do not invent risky capabilities or integrations unless the user strongly implies them.
        """,
        Jason.encode!(payload),
        schema
      )

    case result do
      {:ok, worker_output} ->
        spec
        |> deep_merge(compose_spec_patch(worker_output))
        |> put_string_path(["status"], "discovering")
        |> ensure_spec_defaults(message)

      {:error, reason} ->
        Logger.warning("[AgentBuilderSetup] Orchestrator fallback: #{inspect(reason)}")
        fallback_orchestrated_spec(spec, message, active_agent)
    end
  end

  defp clarify_spec(spec) do
    schema = %{
      type: "object",
      properties: %{
        shouldAskUser: %{type: "boolean"},
        missingCriticalFields: string_array_schema(),
        assistantReply: string_schema(true),
        questionGoals: %{
          type: "array",
          items: %{
            type: "object",
            properties: %{
              fieldKey: string_schema(),
              label: string_schema(),
              reason: string_schema(true),
              preferredType: string_schema(true)
            }
          }
        }
      }
    }

    case call_structured_worker(
           @worker_model,
           """
           You are Clarifier for Vibe's guided agent builder.
           Inspect the setup spec and decide whether the user must answer more questions before a publish-ready draft can be reviewed.
           Only ask when the missing information materially affects the agent's real behavior, required data, tool selection, integrations, destination, or safety.
           Treat branding and polish fields such as display name, username, persona, tone, language, welcome copy, and prompt wording as non-blocking unless the user explicitly asked for them.
           Prioritize high-information operational questions in this order:
           1. What the agent must actually do.
           2. What business data, pricing, catalog, documents, orders, trades, or integrations it needs.
           3. What actions it may take automatically versus what needs approval or handoff.
           4. Who it serves and where outputs should land when that changes runtime behavior.
           Avoid subjective questions like tone unless they are clearly necessary.
           Ask for at most 3 fields.
           """,
           Jason.encode!(spec),
           schema
         ) do
      {:ok, result} ->
        missing_fields = material_missing_fields(spec, result["missingCriticalFields"])
        question_goals =
          prioritize_question_goals(
            spec,
            result["questionGoals"],
            missing_fields
          )

        %{
          "shouldAskUser" => result["shouldAskUser"] == true and question_goals != [],
          "missingCriticalFields" => missing_fields,
          "assistantReply" => normalize_optional_string(result["assistantReply"]),
          "questionGoals" => question_goals
        }

      {:error, reason} ->
        Logger.warning("[AgentBuilderSetup] Clarifier fallback: #{inspect(reason)}")
        fallback_clarifier(spec)
    end
  end

  defp compose_question_request(spec, clarifier_result, previous_request, active_agent, callback) do
    question_goals = clarifier_result["questionGoals"] || []

    schema = %{
      type: "object",
      properties: %{
        title: string_schema(),
        description: string_schema(true),
        submitLabel: string_schema(),
        allowSkip: %{type: "boolean"},
        fields: %{
          type: "array",
          items: %{
            type: "object",
            properties: %{
              key: string_schema(),
              type: string_schema(),
              label: string_schema(),
              required: %{type: "boolean"},
              placeholder: string_schema(true),
              renderHint: string_schema(true),
              allowCustom: %{type: "boolean"},
              options: %{
                type: "array",
                items: %{
                  type: "object",
                  properties: %{
                    id: string_schema(),
                    label: string_schema(),
                    hint: string_schema(true)
                  }
                }
              }
            }
          }
        }
      }
    }

    payload = %{
      spec: spec,
      previous_request: previous_request,
      active_agent: summarize_active_agent(active_agent),
      question_goals: question_goals,
      allowed_field_keys: @field_keys
    }

    result =
      call_structured_worker(
        @worker_model,
        """
        You are QuestionComposer for Vibe's guided agent builder.
        Convert clarification goals into one concise mobile sheet request.
        Use only supported field keys from allowed_field_keys.
        Keep it to at most 3 fields.
        Prefer selects over text when practical.
        Make the sheet feel operational and concrete.
        Use labels that ask for business-critical inputs such as required tasks, business data, source documents, pricing context, integrations, approvals, and destination chats.
        Do not ask about tone, persona, naming, or other polish unless the field is explicitly present in question_goals.
        The sheet is the primary UI for this turn, so keep the description brief and avoid repeating a long assistant message.
        For chat selection use type=chat_picker.
        """,
        Jason.encode!(payload),
        schema
      )

    request =
      case result do
        {:ok, worker_request} ->
          normalize_ui_request(worker_request, spec) ||
            fallback_ui_request(spec, clarifier_result)

        {:error, reason} ->
          Logger.warning("[AgentBuilderSetup] Question composer fallback: #{inspect(reason)}")
          fallback_ui_request(spec, clarifier_result)
      end

    emit(callback, :ui_request, %{pendingUiRequest: request})
    request
  end

  defp build_prompt_assets(spec) do
    schema = %{
      type: "object",
      properties: %{
        systemPrompt: string_schema(true),
        welcomeMessage: string_schema(true)
      }
    }

    prompt_context = %{
      business_summary: get_in_string(spec, ["intent", "businessSummary"]),
      primary_jobs: get_in_string(spec, ["intent", "primaryJobs"]),
      audience: get_in_string(spec, ["intent", "audience"]),
      identity: spec["identity"],
      behavior: spec["behavior"],
      capabilities: spec["capabilities"],
      autonomy: spec["autonomy"]
    }

    case call_structured_worker(
           @worker_model,
           """
           You are PromptBuilder for Vibe's guided agent builder.
           Write a production-ready standalone agent system prompt and a short welcome message.
           Keep the prompt practical, constrained, and ready for real users.
           """,
           Jason.encode!(prompt_context),
           schema
         ) do
      {:ok, worker_result} ->
        %{
          "systemPrompt" => normalize_optional_string(worker_result["systemPrompt"]),
          "welcomeMessage" => normalize_optional_string(worker_result["welcomeMessage"])
        }

      {:error, reason} ->
        Logger.warning("[AgentBuilderSetup] Prompt builder fallback: #{inspect(reason)}")
        fallback_prompt_assets(spec)
    end
  end

  defp build_capability_assets(spec) do
    schema = %{
      type: "object",
      properties: %{
        enabledTools: string_array_schema(),
        outputModes: string_array_schema(),
        suggestedIntegrations: string_array_schema(),
        autonomyMode: string_schema(true),
        blockedActions: string_array_schema(),
        approvalRules: %{type: "object"},
        samplePrompts: string_array_schema(),
        expectedBehaviors: string_array_schema(),
        welcomeMessage: string_schema(true)
      }
    }

    payload = %{
      spec: spec,
      available_tools: Enum.map(ToolRegistry.tools(), fn tool ->
        %{"id" => tool.id, "name" => tool.name, "description" => tool.description}
      end),
      supported_output_modes: ["text", "media", "voice"],
      supported_autonomy_modes: ["manual", "safe_auto", "approval_required"]
    }

    case call_structured_worker(
           @worker_model,
           """
           You are CapabilityPlanner for Vibe's guided agent builder.
           Choose the smallest useful toolset, output modes, guardrails, and test scenarios.
           Default to safe automation, not full autonomy.
           Block risky actions unless the user explicitly requested them.
           """,
           Jason.encode!(payload),
           schema
         ) do
      {:ok, worker_result} ->
        %{
          "enabledTools" => normalize_tool_list(worker_result["enabledTools"]),
          "outputModes" => normalize_output_modes(worker_result["outputModes"]),
          "suggestedIntegrations" => normalize_string_list(worker_result["suggestedIntegrations"]),
          "autonomyMode" => normalize_autonomy_mode(worker_result["autonomyMode"]),
          "blockedActions" => normalize_string_list(worker_result["blockedActions"]),
          "approvalRules" => normalize_map(worker_result["approvalRules"]),
          "samplePrompts" => normalize_string_list(worker_result["samplePrompts"]),
          "expectedBehaviors" => normalize_string_list(worker_result["expectedBehaviors"]),
          "welcomeMessage" => normalize_optional_string(worker_result["welcomeMessage"])
        }

      {:error, reason} ->
        Logger.warning("[AgentBuilderSetup] Capability planner fallback: #{inspect(reason)}")
        fallback_capability_assets(spec)
    end
  end

  defp validate_spec(spec) do
    schema = %{
      type: "object",
      properties: %{
        isReady: %{type: "boolean"},
        confidence: %{type: "number"},
        missingCriticalFields: string_array_schema(),
        overview: string_schema(true),
        sectionSummaries: object_schema(%{
          identity: string_schema(true),
          behavior: string_schema(true),
          tools: string_schema(true),
          integrations: string_schema(true),
          autonomy: string_schema(true),
          tests: string_schema(true)
        })
      }
    }

    case call_structured_worker(
           @orchestrator_model,
           """
           You are Validator for Vibe's guided agent builder.
           Review the assembled spec and decide whether it is ready for the user to create a draft.
           Focus on missing behavior, unclear capabilities, unsafe autonomy, and weak test coverage.
           Do not block readiness on optional identity polish such as name, persona, tone, language, welcome copy, or prompt wording unless the user explicitly requested those details.
           """,
           Jason.encode!(spec),
           schema
         ) do
      {:ok, worker_result} ->
        %{
          "isReady" => worker_result["isReady"] == true,
          "confidence" => normalize_confidence(worker_result["confidence"]),
          "missingCriticalFields" => normalize_string_list(worker_result["missingCriticalFields"]),
          "overview" => normalize_optional_string(worker_result["overview"]),
          "sectionSummaries" => normalize_section_summaries(worker_result["sectionSummaries"])
        }

      {:error, reason} ->
        Logger.warning("[AgentBuilderSetup] Validator fallback: #{inspect(reason)}")
        fallback_validation(spec)
    end
  end

  defp merge_prompt_assets(spec, prompt_result) do
    spec
    |> maybe_put_string_path(["behavior", "systemPrompt"], prompt_result["systemPrompt"])
    |> maybe_put_string_path(["behavior", "welcomeMessage"], prompt_result["welcomeMessage"])
  end

  defp merge_capability_assets(spec, capability_result) do
    spec
    |> put_string_path(["capabilities", "enabledTools"], capability_result["enabledTools"])
    |> put_string_path(["capabilities", "outputModes"], capability_result["outputModes"])
    |> put_string_path(["capabilities", "suggestedIntegrations"], capability_result["suggestedIntegrations"])
    |> put_string_path(["autonomy", "mode"], capability_result["autonomyMode"])
    |> put_string_path(["autonomy", "blockedActions"], capability_result["blockedActions"])
    |> put_string_path(["autonomy", "approvalRules"], capability_result["approvalRules"])
    |> put_string_path(["tests", "samplePrompts"], capability_result["samplePrompts"])
    |> put_string_path(["tests", "expectedBehaviors"], capability_result["expectedBehaviors"])
    |> maybe_put_string_path(["behavior", "welcomeMessage"], capability_result["welcomeMessage"])
  end

  defp build_review_sections(spec, validation) do
    section_summaries = validation["sectionSummaries"] || %{}

    [
      %{
        "id" => "identity",
        "title" => "Identity",
        "summary" =>
          normalize_optional_string(section_summaries["identity"]) ||
            review_identity_summary(spec),
        "editable" => true,
        "requestId" => "setup:edit:identity",
        "fields" => [
          text_field("display_name", "Agent name", true, get_in_string(spec, ["identity", "displayName"])),
          long_text_field("persona", "Persona", false, get_in_string(spec, ["identity", "persona"])),
          select_field(
            "tone",
            "Tone",
            false,
            tone_options(get_in_string(spec, ["identity", "tone"])),
            "tabs",
            true,
            get_in_string(spec, ["identity", "tone"])
          )
        ]
      },
      %{
        "id" => "behavior",
        "title" => "Role & Behavior",
        "summary" =>
          normalize_optional_string(section_summaries["behavior"]) ||
            review_behavior_summary(spec),
        "editable" => true,
        "requestId" => "setup:edit:behavior",
        "fields" => [
          long_text_field("business_summary", "Business summary", true, get_in_string(spec, ["intent", "businessSummary"])),
          long_text_field("system_prompt", "System prompt", false, get_in_string(spec, ["behavior", "systemPrompt"])),
          long_text_field("welcome_message", "Welcome message", false, get_in_string(spec, ["behavior", "welcomeMessage"]))
        ]
      },
      %{
        "id" => "tools",
        "title" => "Tools",
        "summary" =>
          normalize_optional_string(section_summaries["tools"]) ||
            review_tools_summary(spec),
        "editable" => true,
        "requestId" => "setup:edit:tools",
        "fields" => [
          multi_select_field(
            "enabled_tools",
            "Enabled tools",
            true,
            Enum.map(ToolRegistry.tools(), fn tool ->
              %{"id" => tool.id, "label" => tool.name, "hint" => tool.description}
            end),
            "chips",
            false,
            get_in_string(spec, ["capabilities", "enabledTools"])
          ),
          multi_select_field(
            "output_modes",
            "Output modes",
            true,
            [
              %{"id" => "text", "label" => "Text"},
              %{"id" => "media", "label" => "Media"},
              %{"id" => "voice", "label" => "Voice"}
            ],
            "chips",
            false,
            get_in_string(spec, ["capabilities", "outputModes"])
          )
        ]
      },
      %{
        "id" => "integrations",
        "title" => "Integrations",
        "summary" =>
          normalize_optional_string(section_summaries["integrations"]) ||
            review_integrations_summary(spec),
        "editable" => true,
        "requestId" => "setup:edit:integrations",
        "fields" => [
          chat_picker_field(
            "default_destination_chat_id",
            "Default destination chat",
            false,
            get_in_string(spec, ["capabilities", "defaultDestinationChatId"])
          ),
          multi_select_field(
            "suggested_integrations",
            "Suggested event sources",
            false,
            generic_integration_options(get_in_string(spec, ["capabilities", "suggestedIntegrations"])),
            "chips",
            true,
            get_in_string(spec, ["capabilities", "suggestedIntegrations"])
          )
        ]
      },
      %{
        "id" => "autonomy",
        "title" => "Autonomy",
        "summary" =>
          normalize_optional_string(section_summaries["autonomy"]) ||
            review_autonomy_summary(spec),
        "editable" => true,
        "requestId" => "setup:edit:autonomy",
        "fields" => [
          select_field(
            "autonomy_mode",
            "Autonomy",
            true,
            [
              %{"id" => "manual", "label" => "Manual", "hint" => "Draft first and let humans decide."},
              %{"id" => "safe_auto", "label" => "Safe Auto", "hint" => "Handle low-risk work automatically."},
              %{"id" => "approval_required", "label" => "Approval Required", "hint" => "Prepare actions but wait for approval."}
            ],
            "tabs",
            false,
            get_in_string(spec, ["autonomy", "mode"])
          ),
          long_text_field("blocked_actions", "Blocked actions", false, Enum.join(get_in_string(spec, ["autonomy", "blockedActions"]) || [], "\n")),
          long_text_field("escalation_policy", "Escalation policy", false, get_in_string(spec, ["behavior", "escalationPolicy"]))
        ]
      },
      %{
        "id" => "tests",
        "title" => "Test Scenarios",
        "summary" =>
          normalize_optional_string(section_summaries["tests"]) ||
            review_tests_summary(spec),
        "editable" => true,
        "requestId" => "setup:edit:tests",
        "fields" => [
          long_text_field("sample_prompts", "Sample prompts", false, Enum.join(get_in_string(spec, ["tests", "samplePrompts"]) || [], "\n")),
          long_text_field("expected_behaviors", "Expected behaviors", false, Enum.join(get_in_string(spec, ["tests", "expectedBehaviors"]) || [], "\n"))
        ]
      }
    ]
  end

  defp build_virtual_draft_patch(spec, active_agent) do
    base =
      case active_agent do
        %{} = agent -> Agents.agent_payload(agent)
        _ -> %{}
      end

    Map.merge(base, %{
      displayName: get_in_string(spec, ["identity", "displayName"]) || base[:displayName] || base["displayName"],
      username: get_in_string(spec, ["identity", "username"]) || base[:username] || base["username"],
      persona: get_in_string(spec, ["identity", "persona"]) || base[:persona] || base["persona"],
      systemPrompt: get_in_string(spec, ["behavior", "systemPrompt"]) || base[:systemPrompt] || base["systemPrompt"],
      welcomeMessage: get_in_string(spec, ["behavior", "welcomeMessage"]) || base[:welcomeMessage] || base["welcomeMessage"],
      enabledTools: get_in_string(spec, ["capabilities", "enabledTools"]) || base[:enabledTools] || base["enabledTools"] || [],
      outputModes: get_in_string(spec, ["capabilities", "outputModes"]) || base[:outputModes] || base["outputModes"] || ["text"],
      autonomyMode: get_in_string(spec, ["autonomy", "mode"]) || base[:autonomyMode] || base["autonomyMode"] || "safe_auto",
      defaultDestinationChatId:
        get_in_string(spec, ["capabilities", "defaultDestinationChatId"]) ||
          base[:defaultDestinationChatId] ||
          base["defaultDestinationChatId"],
      approvalRules: get_in_string(spec, ["autonomy", "approvalRules"]) || base[:approvalRules] || base["approvalRules"] || %{},
      eventTypesEnabled: base[:eventTypesEnabled] || base["eventTypesEnabled"] || []
    })
  end

  defp build_draft_attrs(spec) do
    %{}
    |> maybe_put("display_name", get_in_string(spec, ["identity", "displayName"]) || default_display_name(spec))
    |> maybe_put("username", get_in_string(spec, ["identity", "username"]))
    |> maybe_put("persona", get_in_string(spec, ["identity", "persona"]))
    |> maybe_put("system_prompt", get_in_string(spec, ["behavior", "systemPrompt"]))
    |> maybe_put("welcome_message", get_in_string(spec, ["behavior", "welcomeMessage"]))
    |> maybe_put("enabled_tools", normalize_tool_list(get_in_string(spec, ["capabilities", "enabledTools"])))
    |> maybe_put("output_modes", normalize_output_modes(get_in_string(spec, ["capabilities", "outputModes"])))
    |> maybe_put("autonomy_mode", normalize_autonomy_mode(get_in_string(spec, ["autonomy", "mode"])))
    |> maybe_put("default_destination_chat_id", get_in_string(spec, ["capabilities", "defaultDestinationChatId"]))
    |> maybe_put("approval_rules", normalize_map(get_in_string(spec, ["autonomy", "approvalRules"])))
  end

  defp normalize_setup_spec(nil, active_agent) do
    normalize_setup_spec(%{}, active_agent)
  end

  defp normalize_setup_spec(raw, active_agent) do
    base = %{
      "version" => 1,
      "status" => "discovering",
      "intent" => %{
        "rawRequest" => "",
        "businessSummary" => "",
        "businessType" => nil,
        "audience" => [],
        "primaryJobs" => [],
        "successCriteria" => []
      },
      "identity" => %{
        "displayName" => nil,
        "username" => nil,
        "persona" => nil,
        "tone" => nil,
        "language" => nil
      },
      "behavior" => %{
        "systemPrompt" => nil,
        "welcomeMessage" => nil,
        "doList" => [],
        "dontList" => [],
        "escalationPolicy" => nil
      },
      "capabilities" => %{
        "enabledTools" => Agents.default_enabled_tools(),
        "outputModes" => Agents.default_output_modes(),
        "suggestedIntegrations" => [],
        "defaultDestinationChatId" => nil
      },
      "autonomy" => %{
        "mode" => "safe_auto",
        "approvalRules" => %{},
        "blockedActions" => []
      },
      "publishing" => %{
        "isReady" => false,
        "missingCriticalFields" => [],
        "confidence" => 0.0
      },
      "tests" => %{
        "samplePrompts" => [],
        "expectedBehaviors" => []
      }
    }

    active_agent_patch =
      case active_agent do
        %{} = agent ->
          %{
            "identity" => %{
              "displayName" => agent.display_name,
              "persona" => agent.persona,
              "username" => agent.agent_user && agent.agent_user.username
            },
            "behavior" => %{
              "systemPrompt" => agent.system_prompt,
              "welcomeMessage" => agent.welcome_message
            },
            "capabilities" => %{
              "enabledTools" => agent.enabled_tools || Agents.default_enabled_tools(),
              "outputModes" => agent.output_modes || Agents.default_output_modes(),
              "defaultDestinationChatId" => agent.default_destination_chat_id
            },
            "autonomy" => %{
              "mode" => normalize_autonomy_mode(agent.autonomy_mode),
              "approvalRules" => agent.approval_rules || %{}
            }
          }

        _ ->
          %{}
      end

    base
    |> deep_merge(active_agent_patch)
    |> deep_merge(normalize_map(raw))
    |> ensure_spec_defaults(nil)
  end

  defp ensure_spec_defaults(spec, latest_message) do
    business_summary =
      get_in_string(spec, ["intent", "businessSummary"]) ||
        normalize_optional_string(latest_message) ||
        get_in_string(spec, ["intent", "rawRequest"]) ||
        ""

    spec
    |> put_string_path(["intent", "businessSummary"], business_summary)
    |> maybe_put_string_path(["identity", "displayName"], default_display_name(spec))
    |> put_string_path(["capabilities", "enabledTools"], normalize_tool_list(get_in_string(spec, ["capabilities", "enabledTools"])))
    |> put_string_path(["capabilities", "outputModes"], normalize_output_modes(get_in_string(spec, ["capabilities", "outputModes"])))
    |> put_string_path(["autonomy", "mode"], normalize_autonomy_mode(get_in_string(spec, ["autonomy", "mode"])))
    |> put_string_path(["autonomy", "approvalRules"], normalize_map(get_in_string(spec, ["autonomy", "approvalRules"])))
  end

  defp build_setup_state(spec, status) do
    normalized_status =
      case normalize_optional_string(status) do
        value when value in @status_values -> value
        _ -> "discovering"
      end

    confidence =
      normalize_confidence(
        get_in_string(spec, ["publishing", "confidence"]) ||
          get_in_string(spec, ["confidence"])
      )

    %{
      "status" => normalized_status,
      "phase" => phase_for_status(normalized_status),
      "summary" => get_in_string(spec, ["intent", "businessSummary"]),
      "confidence" => confidence
    }
  end

  defp phase_for_status(status) when status in ["discovering", "clarifying"], do: "understand"
  defp phase_for_status(status) when status in ["assembling"], do: "configure"
  defp phase_for_status(_status), do: "review"

  defp build_draft_created_reply(agent, latest_secret) do
    name = agent.display_name || "agent"

    if is_binary(latest_secret) do
      "Created #{name}. The draft is ready, and the new invoke secret is available in this session."
    else
      "Created #{name}. The draft is ready for refinement, testing, or publish."
    end
  end

  defp default_display_name(spec) do
    base =
      get_in_string(spec, ["intent", "businessType"]) ||
        get_in_string(spec, ["intent", "businessSummary"]) ||
        "New Agent"

    base
    |> to_string()
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9 ]+/, " ")
    |> String.split()
    |> Enum.take(4)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
    |> case do
      "" -> "New Agent"
      value ->
        cond do
          String.ends_with?(String.downcase(value), "agent") -> value
          true -> "#{value} Agent"
        end
    end
    |> String.slice(0, 80)
  end

  defp review_identity_summary(spec) do
    display_name = get_in_string(spec, ["identity", "displayName"]) || "Unnamed agent"
    persona = get_in_string(spec, ["identity", "persona"])
    tone = get_in_string(spec, ["identity", "tone"])

    [display_name, persona, tone]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" • ")
  end

  defp review_behavior_summary(spec) do
    summary = get_in_string(spec, ["intent", "businessSummary"]) || "No business summary yet."
    prompt = get_in_string(spec, ["behavior", "systemPrompt"])

    if is_binary(prompt) and String.trim(prompt) != "" do
      "#{summary} Prompt drafted."
    else
      summary
    end
  end

  defp review_tools_summary(spec) do
    tools = get_in_string(spec, ["capabilities", "enabledTools"]) || []
    modes = get_in_string(spec, ["capabilities", "outputModes"]) || []
    "#{Enum.join(tools, ", ")} • #{Enum.join(modes, ", ")}"
  end

  defp review_integrations_summary(spec) do
    integrations = get_in_string(spec, ["capabilities", "suggestedIntegrations"]) || []
    destination = get_in_string(spec, ["capabilities", "defaultDestinationChatId"])

    parts =
      [if(destination, do: "Chat selected", else: nil), if(integrations != [], do: Enum.join(integrations, ", "), else: nil)]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: "No destination or event sources selected yet.", else: Enum.join(parts, " • ")
  end

  defp review_autonomy_summary(spec) do
    mode = get_in_string(spec, ["autonomy", "mode"]) || "safe_auto"
    blocked = get_in_string(spec, ["autonomy", "blockedActions"]) || []
    blocked_text = if blocked == [], do: "No blocked actions listed.", else: "#{length(blocked)} blocked actions"
    "#{mode} • #{blocked_text}"
  end

  defp review_tests_summary(spec) do
    prompts = get_in_string(spec, ["tests", "samplePrompts"]) || []
    behaviors = get_in_string(spec, ["tests", "expectedBehaviors"]) || []
    "#{length(prompts)} sample prompt#{if length(prompts) == 1, do: "", else: "s"} • #{length(behaviors)} expected behavior#{if length(behaviors) == 1, do: "", else: "s"}"
  end

  defp text_field(key, label, required, value) do
    %{
      "key" => key,
      "type" => "text",
      "label" => label,
      "required" => required,
      "value" => value
    }
  end

  defp long_text_field(key, label, required, value) do
    %{
      "key" => key,
      "type" => "long_text",
      "label" => label,
      "required" => required,
      "value" => value
    }
  end

  defp select_field(key, label, required, options, render_hint, allow_custom, value) do
    %{
      "key" => key,
      "type" => "single_select",
      "label" => label,
      "required" => required,
      "options" => options,
      "renderHint" => render_hint,
      "allowCustom" => allow_custom,
      "value" => value
    }
  end

  defp multi_select_field(key, label, required, options, render_hint, allow_custom, value) do
    %{
      "key" => key,
      "type" => "multi_select",
      "label" => label,
      "required" => required,
      "options" => options,
      "renderHint" => render_hint,
      "allowCustom" => allow_custom,
      "value" => value
    }
  end

  defp chat_picker_field(key, label, required, value) do
    %{
      "key" => key,
      "type" => "chat_picker",
      "label" => label,
      "required" => required,
      "value" => value
    }
  end

  defp tone_options(current_tone) do
    options = [
      %{"id" => "friendly", "label" => "Friendly"},
      %{"id" => "premium", "label" => "Premium"},
      %{"id" => "professional", "label" => "Professional"},
      %{"id" => "playful", "label" => "Playful"}
    ]

    if is_binary(current_tone) and current_tone != "" and Enum.all?(options, &(&1["id"] != current_tone)) do
      options ++ [%{"id" => current_tone, "label" => current_tone}]
    else
      options
    end
  end

  defp generic_integration_options(current_values) do
    base = [
      %{"id" => "orders", "label" => "Orders"},
      %{"id" => "trades", "label" => "Trades"},
      %{"id" => "tickets", "label" => "Tickets"},
      %{"id" => "alerts", "label" => "Alerts"}
    ]

    normalize_string_list(current_values)
    |> Enum.reduce(base, fn value, acc ->
      if Enum.any?(acc, &(&1["id"] == value)) do
        acc
      else
        acc ++ [%{"id" => value, "label" => value}]
      end
    end)
  end

  defp summarize_ui_answers(request, answers) do
    labels_by_key =
      request["fields"]
      |> List.wrap()
      |> Enum.into(%{}, fn field -> {field["key"], field["label"]} end)

    values =
      answers
      |> Enum.map(fn {key, value} ->
        label = Map.get(labels_by_key, key, key)
        rendered = render_answer_value(value)
        if rendered == "", do: nil, else: "#{label}: #{rendered}"
      end)
      |> Enum.reject(&is_nil/1)

    case values do
      [] -> normalize_optional_string(request["title"]) || "Updated setup answers."
      _ -> Enum.join(values, " • ")
    end
  end

  defp render_answer_value(value) when is_binary(value), do: String.trim(value)
  defp render_answer_value(value) when is_list(value), do: Enum.join(normalize_string_list(value), ", ")
  defp render_answer_value(value), do: to_string(value || "")

  defp apply_answers_to_spec(spec, fields, answers) do
    Enum.reduce(fields, spec, fn field, acc ->
      key = normalize_optional_string(field["key"])
      raw_value = Map.get(answers, key)

      if is_nil(key) or is_nil(raw_value) do
        acc
      else
        apply_answer(acc, key, raw_value)
      end
    end)
    |> put_string_path(["status"], "assembling")
  end

  defp apply_answer(spec, "business_summary", value),
    do: put_string_path(spec, ["intent", "businessSummary"], normalize_optional_string(value) || "")

  defp apply_answer(spec, "business_type", value),
    do: put_string_path(spec, ["intent", "businessType"], normalize_optional_string(value))

  defp apply_answer(spec, "audience", value),
    do: put_string_path(spec, ["intent", "audience"], normalize_string_list(value))

  defp apply_answer(spec, "primary_jobs", value),
    do: put_string_path(spec, ["intent", "primaryJobs"], normalize_string_list(value))

  defp apply_answer(spec, "success_criteria", value),
    do: put_string_path(spec, ["intent", "successCriteria"], normalize_string_list_or_text(value))

  defp apply_answer(spec, "display_name", value),
    do: put_string_path(spec, ["identity", "displayName"], normalize_optional_string(value))

  defp apply_answer(spec, "username", value),
    do: put_string_path(spec, ["identity", "username"], normalize_optional_string(value))

  defp apply_answer(spec, "persona", value),
    do: put_string_path(spec, ["identity", "persona"], normalize_optional_string(value))

  defp apply_answer(spec, "tone", value),
    do: put_string_path(spec, ["identity", "tone"], normalize_optional_string(value))

  defp apply_answer(spec, "language", value),
    do: put_string_path(spec, ["identity", "language"], normalize_optional_string(value))

  defp apply_answer(spec, "system_prompt", value),
    do: put_string_path(spec, ["behavior", "systemPrompt"], normalize_optional_string(value))

  defp apply_answer(spec, "welcome_message", value),
    do: put_string_path(spec, ["behavior", "welcomeMessage"], normalize_optional_string(value))

  defp apply_answer(spec, "do_list", value),
    do: put_string_path(spec, ["behavior", "doList"], normalize_string_list_or_text(value))

  defp apply_answer(spec, "dont_list", value),
    do: put_string_path(spec, ["behavior", "dontList"], normalize_string_list_or_text(value))

  defp apply_answer(spec, "escalation_policy", value),
    do: put_string_path(spec, ["behavior", "escalationPolicy"], normalize_optional_string(value))

  defp apply_answer(spec, "enabled_tools", value),
    do: put_string_path(spec, ["capabilities", "enabledTools"], normalize_tool_list(value))

  defp apply_answer(spec, "output_modes", value),
    do: put_string_path(spec, ["capabilities", "outputModes"], normalize_output_modes(value))

  defp apply_answer(spec, "suggested_integrations", value),
    do: put_string_path(spec, ["capabilities", "suggestedIntegrations"], normalize_string_list(value))

  defp apply_answer(spec, "default_destination_chat_id", value),
    do: put_string_path(spec, ["capabilities", "defaultDestinationChatId"], normalize_optional_string(value))

  defp apply_answer(spec, "autonomy_mode", value),
    do: put_string_path(spec, ["autonomy", "mode"], normalize_autonomy_mode(value))

  defp apply_answer(spec, "blocked_actions", value),
    do: put_string_path(spec, ["autonomy", "blockedActions"], normalize_string_list_or_text(value))

  defp apply_answer(spec, "sample_prompts", value),
    do: put_string_path(spec, ["tests", "samplePrompts"], normalize_string_list_or_text(value))

  defp apply_answer(spec, "expected_behaviors", value),
    do: put_string_path(spec, ["tests", "expectedBehaviors"], normalize_string_list_or_text(value))

  defp apply_answer(spec, _key, _value), do: spec

  defp fallback_orchestrated_spec(spec, message, _active_agent) do
    primary_jobs =
      cond do
        String.contains?(String.downcase(message), "support") -> ["customer support"]
        String.contains?(String.downcase(message), "sales") -> ["sales"]
        String.contains?(String.downcase(message), "order") -> ["order updates"]
        true -> []
      end

    spec
    |> put_string_path(["intent", "rawRequest"], message)
    |> put_string_path(["intent", "businessSummary"], message)
    |> put_string_path(["intent", "primaryJobs"], primary_jobs)
    |> maybe_put_string_path(["identity", "displayName"], default_display_name(spec))
    |> put_string_path(["status"], "discovering")
  end

  defp fallback_clarifier(spec) do
    summary =
      [
        get_in_string(spec, ["intent", "rawRequest"]),
        get_in_string(spec, ["intent", "businessSummary"]),
        Enum.join(get_in_string(spec, ["intent", "primaryJobs"]) || [], " "),
        Enum.join(get_in_string(spec, ["capabilities", "suggestedIntegrations"]) || [], " ")
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    missing_candidates =
      []
      |> maybe_append_missing(get_in_string(spec, ["intent", "primaryJobs"]) in [nil, []], "primary_jobs")
      |> maybe_append_missing(blank?(get_in_string(spec, ["intent", "businessSummary"])), "business_summary")
      |> maybe_append_missing(
        suggested_integrations_missing?(spec, summary),
        "suggested_integrations"
      )
      |> maybe_append_missing(
        enabled_tools_missing?(spec, summary),
        "enabled_tools"
      )
      |> maybe_append_missing(
        blocked_actions_missing?(spec, summary),
        "blocked_actions"
      )
      |> maybe_append_missing(
        requires_destination_chat?(spec),
        "default_destination_chat_id"
      )

    missing = material_missing_fields(spec, missing_candidates)

    question_goals =
      missing
      |> Enum.map(fn field ->
        %{
          "fieldKey" => field,
          "label" => humanize_field_key(field),
          "reason" => "Needed to finish the draft",
          "preferredType" => preferred_field_type(field)
        }
      end)
      |> prioritize_question_goals(spec, missing)

    %{
      "shouldAskUser" => missing != [],
      "missingCriticalFields" => missing,
      "assistantReply" => nil,
      "questionGoals" => question_goals
    }
  end

  defp maybe_append_missing(list, true, value), do: list ++ [value]
  defp maybe_append_missing(list, false, _value), do: list

  defp fallback_ui_request(spec, clarifier_result) do
    fields =
      clarifier_result["questionGoals"]
      |> Enum.take(3)
      |> Enum.map(fn goal ->
        build_fallback_field(goal["fieldKey"], spec)
      end)
      |> Enum.reject(&is_nil/1)

    %{
      "id" => "setup:clarify:#{System.system_time(:millisecond)}",
      "presentation" => "sheet",
      "title" => "A few details to finish the setup",
      "description" => "These answers tighten the prompt, tool choices, and review draft.",
      "submitLabel" => "Continue",
      "allowSkip" => true,
      "fields" => fields
    }
  end

  defp build_fallback_field("primary_jobs", spec) do
    multi_select_field(
      "primary_jobs",
      "Main jobs",
      true,
      [
        %{"id" => "sales", "label" => "Sales"},
        %{"id" => "customer support", "label" => "Customer support"},
        %{"id" => "order updates", "label" => "Order updates"},
        %{"id" => "operations", "label" => "Operations"}
      ],
      "chips",
      true,
      get_in_string(spec, ["intent", "primaryJobs"])
    )
  end

  defp build_fallback_field("business_summary", spec) do
    long_text_field(
      "business_summary",
      "What should the agent handle?",
      true,
      get_in_string(spec, ["intent", "businessSummary"])
    )
  end

  defp build_fallback_field("default_destination_chat_id", spec) do
    chat_picker_field(
      "default_destination_chat_id",
      "Where should event updates go?",
      false,
      get_in_string(spec, ["capabilities", "defaultDestinationChatId"])
    )
  end

  defp build_fallback_field("audience", spec) do
    multi_select_field(
      "audience",
      "Who talks to this agent?",
      false,
      [
        %{"id" => "customers", "label" => "Customers"},
        %{"id" => "internal team", "label" => "Internal team"},
        %{"id" => "admins", "label" => "Admins"}
      ],
      "chips",
      true,
      get_in_string(spec, ["intent", "audience"])
    )
  end

  defp build_fallback_field("enabled_tools", spec) do
    multi_select_field(
      "enabled_tools",
      "What should this agent be able to do?",
      true,
      Enum.map(ToolRegistry.tools(), fn tool ->
        %{"id" => tool.id, "label" => tool.name, "hint" => tool.description}
      end),
      "chips",
      true,
      get_in_string(spec, ["capabilities", "enabledTools"])
    )
  end

  defp build_fallback_field("suggested_integrations", spec) do
    multi_select_field(
      "suggested_integrations",
      "What business data should it use?",
      false,
      generic_integration_options(get_in_string(spec, ["capabilities", "suggestedIntegrations"])),
      "chips",
      true,
      get_in_string(spec, ["capabilities", "suggestedIntegrations"])
    )
  end

  defp build_fallback_field("blocked_actions", spec) do
    long_text_field(
      "blocked_actions",
      "What must always need approval?",
      false,
      get_in_string(spec, ["autonomy", "blockedActions"])
    )
  end

  defp build_fallback_field("success_criteria", spec) do
    long_text_field(
      "success_criteria",
      "What should success look like?",
      false,
      get_in_string(spec, ["intent", "successCriteria"])
    )
  end

  defp build_fallback_field("do_list", spec) do
    long_text_field(
      "do_list",
      "What should the agent definitely handle?",
      false,
      get_in_string(spec, ["behavior", "doList"])
    )
  end

  defp build_fallback_field("escalation_policy", spec) do
    long_text_field(
      "escalation_policy",
      "When should it hand off to a person?",
      false,
      get_in_string(spec, ["behavior", "escalationPolicy"])
    )
  end

  defp build_fallback_field("tone", spec) do
    select_field(
      "tone",
      "Tone",
      false,
      tone_options(get_in_string(spec, ["identity", "tone"])),
      "tabs",
      true,
      get_in_string(spec, ["identity", "tone"])
    )
  end

  defp build_fallback_field("autonomy_mode", spec) do
    select_field(
      "autonomy_mode",
      "Autonomy",
      true,
      [
        %{"id" => "manual", "label" => "Manual"},
        %{"id" => "safe_auto", "label" => "Safe Auto"},
        %{"id" => "approval_required", "label" => "Approval Required"}
      ],
      "tabs",
      false,
      get_in_string(spec, ["autonomy", "mode"])
    )
  end

  defp build_fallback_field(_field_key, _spec), do: nil

  defp fallback_prompt_assets(spec) do
    description =
      get_in_string(spec, ["intent", "businessSummary"]) ||
        default_display_name(spec)

    case GroupAgent.generate_system_prompt(description, get_in_string(spec, ["capabilities", "enabledTools"])) do
      {:ok, prompt} ->
        %{
          "systemPrompt" => prompt,
          "welcomeMessage" =>
            "Hi, I’m #{get_in_string(spec, ["identity", "displayName"]) || default_display_name(spec)}. How can I help?"
        }

      {:error, _reason} ->
        %{
          "systemPrompt" => """
          You are #{get_in_string(spec, ["identity", "displayName"]) || default_display_name(spec)}.
          Help with #{description}.
          Be concise, accurate, and escalate unclear or risky requests.
          """
          |> String.trim(),
          "welcomeMessage" => "Hi, how can I help?"
        }
    end
  end

  defp fallback_capability_assets(spec) do
    jobs = Enum.join(get_in_string(spec, ["intent", "primaryJobs"]) || [], " ")
    summary = String.downcase("#{jobs} #{get_in_string(spec, ["intent", "businessSummary"]) || ""}")

    enabled_tools =
      cond do
        String.contains?(summary, "document") -> ["create_document", "export_rows"]
        String.contains?(summary, "image") -> ["analyze_image"]
        true -> Enum.take(Agents.default_enabled_tools(), 3)
      end

    %{
      "enabledTools" => normalize_tool_list(enabled_tools),
      "outputModes" => ["text"],
      "suggestedIntegrations" => normalize_string_list(get_in_string(spec, ["capabilities", "suggestedIntegrations"])),
      "autonomyMode" => normalize_autonomy_mode(get_in_string(spec, ["autonomy", "mode"])),
      "blockedActions" => normalize_string_list(get_in_string(spec, ["autonomy", "blockedActions"])),
      "approvalRules" => normalize_map(get_in_string(spec, ["autonomy", "approvalRules"])),
      "samplePrompts" => ["What should I do first?", "Summarize the current status."],
      "expectedBehaviors" => ["Explains its reasoning clearly", "Escalates unclear or risky requests"],
      "welcomeMessage" => get_in_string(spec, ["behavior", "welcomeMessage"])
    }
  end

  defp fallback_validation(spec) do
    missing =
      []
      |> maybe_append_missing(blank?(get_in_string(spec, ["intent", "businessSummary"])), "business_summary")
      |> maybe_append_missing((get_in_string(spec, ["intent", "primaryJobs"]) || []) == [], "primary_jobs")
      |> maybe_append_missing(blank?(get_in_string(spec, ["behavior", "systemPrompt"])), "system_prompt")

    %{
      "isReady" => missing == [],
      "confidence" => if(missing == [], do: 0.82, else: 0.54),
      "missingCriticalFields" => missing,
      "overview" =>
        if(missing == [], do: "The draft is ready for review.", else: "The draft is usable, but a few gaps still affect quality."),
      "sectionSummaries" => %{
        "identity" => review_identity_summary(spec),
        "behavior" => review_behavior_summary(spec),
        "tools" => review_tools_summary(spec),
        "integrations" => review_integrations_summary(spec),
        "autonomy" => review_autonomy_summary(spec),
        "tests" => review_tests_summary(spec)
      }
    }
  end

  defp call_structured_worker(model, system_prompt, user_prompt, schema) do
    messages = [
      %{
        role: "user",
        content: """
        Return the answer by calling #{@structured_worker_tool} once.

        #{user_prompt}
        """
      }
    ]

    config = %AgentRuntime.Config{
      model: model,
      max_tokens: 1600,
      max_depth: 1,
      system_prompt: String.trim(system_prompt),
      tools: [
        %{
          name: @structured_worker_tool,
          description: "Return the structured result for this worker.",
          input_schema: schema
        }
      ],
      state: %{worker_result: nil},
      callback: nil,
      stream_text?: false,
      execute_tools: &execute_structured_worker_tools/3,
      missing_api_key_error: :missing_api_key,
      depth_error: :missing_tool_use,
      request_label: "AgentBuilderSetupWorker"
    }

    with {:ok, raw_reply, final_state} <- AgentRuntime.run(messages, config) do
      case Map.get(final_state, :worker_result) do
        result when is_map(result) and map_size(result) > 0 ->
          {:ok, result}

        _ ->
          parse_worker_text(raw_reply)
      end
    end
  end

  defp execute_structured_worker_tools(tool_calls, state, _callback) do
    Enum.reduce(tool_calls, {[], state}, fn tool, {results, acc_state} ->
      tool_input = normalize_map(tool["input"])

      next_state =
        case tool["name"] do
          @structured_worker_tool when map_size(tool_input) > 0 ->
            Map.put(acc_state, :worker_result, tool_input)

          _ ->
            acc_state
        end

      tool_result = %{
        type: "tool_result",
        tool_use_id: tool["id"],
        content: Jason.encode!(%{"ok" => true})
      }

      {results ++ [tool_result], next_state}
    end)
  end

  defp parse_worker_text(text) when is_binary(text) do
    trimmed = String.trim(text)

    with [_full, json] <- Regex.run(~r/(\{.*\})/s, trimmed),
         {:ok, decoded} <- Jason.decode(json) do
      {:ok, decoded}
    else
      _ -> {:error, :missing_tool_use}
    end
  end

  defp parse_worker_text(_text), do: {:error, :missing_tool_use}

  defp emit(nil, _type, _data), do: :ok

  defp emit(callback, type, data) when is_function(callback, 1) do
    callback.(%{type: type, data: data})
  end

  defp normalize_metadata(metadata, active_agent_id) do
    map =
      metadata
      |> normalize_map()
      |> Map.put_new("pending_ui_request", nil)
      |> Map.put_new("review_sections", [])
      |> Map.put_new("activity", [])
      |> Map.put_new("setup_state", nil)

    if is_binary(active_agent_id), do: Map.put(map, "active_agent_id", active_agent_id), else: map
  end

  defp normalize_setup_state_payload(nil), do: nil

  defp normalize_setup_state_payload(state) do
    normalized = normalize_map(state)
    status = normalize_optional_string(normalized["status"]) || "discovering"

    %{
      status: status,
      phase: normalize_optional_string(normalized["phase"]) || phase_for_status(status),
      summary: normalize_optional_string(normalized["summary"]),
      confidence: normalize_confidence(normalized["confidence"])
    }
  end

  defp normalize_activity(items) do
    items
    |> List.wrap()
    |> Enum.map(fn item ->
      normalized = normalize_map(item)

      %{
        id: normalize_optional_string(normalized["id"]) || "step",
        title: normalize_optional_string(normalized["title"]) || "Step",
        status: normalize_optional_string(normalized["status"]) || "pending",
        detail: normalize_optional_string(normalized["detail"]),
        agentLabel: normalize_optional_string(normalized["agentLabel"] || normalized["agent_label"]),
        prompt: normalize_optional_string(normalized["prompt"]),
        parentId: normalize_optional_string(normalized["parentId"] || normalized["parent_id"]),
        depth:
          case normalized["depth"] do
            value when is_integer(value) -> value
            value when is_float(value) -> trunc(value)
            _ -> nil
          end
      }
    end)
  end

  defp normalize_public_ui_request(nil), do: nil

  defp normalize_public_ui_request(request) do
    normalize_ui_request(request, %{})
  end

  defp normalize_ui_request(request, spec) do
    normalized = normalize_map(request)
    fields =
      normalized["fields"]
      |> List.wrap()
      |> Enum.take(3)
      |> Enum.map(&normalize_ui_field(&1, spec))
      |> Enum.reject(&is_nil/1)

    if fields == [] do
      nil
    else
      %{
        "id" => normalize_optional_string(normalized["id"]) || "setup:clarify:#{System.system_time(:millisecond)}",
        "presentation" => "sheet",
        "title" => normalize_optional_string(normalized["title"]) || "A few details",
        "description" => normalize_optional_string(normalized["description"]),
        "submitLabel" => normalize_optional_string(normalized["submitLabel"]) || "Continue",
        "allowSkip" => normalized["allowSkip"] == true,
        "fields" => fields
      }
    end
  end

  defp normalize_ui_field(field, spec) do
    normalized = normalize_map(field)
    key = normalize_optional_string(normalized["key"])

    cond do
      is_nil(key) or key not in @field_keys ->
        nil

      true ->
        raw_type = normalize_ui_field_type(key, normalized["type"], normalized["options"])
        options = normalize_field_options(raw_type, normalized["options"], key, spec)
        type = raw_type

        field_payload = %{
          "key" => key,
          "type" => type,
          "label" => normalize_optional_string(normalized["label"]) || humanize_field_key(key),
          "required" => normalized["required"] == true,
          "value" => normalize_field_value(key, normalized["value"], spec)
        }

        field_payload
        |> maybe_put("placeholder", normalize_optional_string(normalized["placeholder"]))
        |> maybe_put("renderHint", normalize_render_hint(normalized["renderHint"]))
        |> Map.put("allowCustom", normalized["allowCustom"] == true)
        |> maybe_put("options", if(type in ["single_select", "multi_select"], do: options, else: nil))
    end
  end

  defp normalize_review_sections(sections) do
    sections
    |> List.wrap()
    |> Enum.map(fn section ->
      normalized = normalize_map(section)

      %{
        id: normalize_optional_string(normalized["id"]) || "section",
        title: normalize_optional_string(normalized["title"]) || "Section",
        summary: normalize_optional_string(normalized["summary"]) || "",
        editable: normalized["editable"] != false,
        requestId: normalize_optional_string(normalized["requestId"]) || "setup:edit:#{normalize_optional_string(normalized["id"]) || "section"}",
        fields:
          normalized["fields"]
          |> List.wrap()
          |> Enum.map(&normalize_ui_field(&1, %{}))
          |> Enum.reject(&is_nil/1)
      }
    end)
  end

  defp normalize_field_options("chat_picker", _options, _key, _spec), do: nil

  defp normalize_field_options(_type, options, key, spec) do
    provided =
      options
      |> List.wrap()
      |> Enum.map(fn option ->
        normalized = normalize_map(option)
        id = normalize_optional_string(normalized["id"])
        label = normalize_optional_string(normalized["label"])

        if is_binary(id) and is_binary(label) do
          %{
            "id" => id,
            "label" => label,
            "hint" => normalize_optional_string(normalized["hint"])
          }
        end
      end)
      |> Enum.reject(&is_nil/1)

    if provided == [] do
      default_field_options(key, spec)
    else
      provided
    end
  end

  defp default_field_options("primary_jobs", _spec) do
    [
      %{"id" => "sales", "label" => "Sales"},
      %{"id" => "customer support", "label" => "Customer support"},
      %{"id" => "order updates", "label" => "Order updates"},
      %{"id" => "operations", "label" => "Operations"}
    ]
  end

  defp default_field_options("audience", _spec) do
    [
      %{"id" => "customers", "label" => "Customers"},
      %{"id" => "internal team", "label" => "Internal team"},
      %{"id" => "admins", "label" => "Admins"}
    ]
  end

  defp default_field_options("business_type", _spec) do
    [
      %{"id" => "ecommerce", "label" => "E-commerce"},
      %{"id" => "services", "label" => "Services"},
      %{"id" => "internal_ops", "label" => "Internal ops"},
      %{"id" => "community", "label" => "Community"},
      %{"id" => "content", "label" => "Content"}
    ]
  end

  defp default_field_options("tone", spec), do: tone_options(get_in_string(spec, ["identity", "tone"]))

  defp default_field_options("enabled_tools", _spec) do
    Enum.map(ToolRegistry.tools(), fn tool ->
      %{"id" => tool.id, "label" => tool.name, "hint" => tool.description}
    end)
  end

  defp default_field_options("output_modes", _spec) do
    [
      %{"id" => "text", "label" => "Text"},
      %{"id" => "media", "label" => "Media"},
      %{"id" => "voice", "label" => "Voice"}
    ]
  end

  defp default_field_options("autonomy_mode", _spec) do
    [
      %{"id" => "manual", "label" => "Manual"},
      %{"id" => "safe_auto", "label" => "Safe Auto"},
      %{"id" => "approval_required", "label" => "Approval Required"}
    ]
  end

  defp default_field_options("suggested_integrations", spec),
    do: generic_integration_options(get_in_string(spec, ["capabilities", "suggestedIntegrations"]))

  defp default_field_options(_key, _spec), do: nil

  defp normalize_field_value(_key, value, _spec) when value in [nil, ""], do: nil
  defp normalize_field_value(_key, value, _spec), do: value

  defp normalize_render_hint(value) do
    case normalize_optional_string(value) do
      "tabs" -> "tabs"
      "chips" -> "chips"
      _ -> "chips"
    end
  end

  defp normalize_question_goals(goals) do
    goals
    |> List.wrap()
    |> Enum.map(fn goal ->
      normalized = normalize_map(goal)
      field_key = normalize_optional_string(normalized["fieldKey"])

      if is_binary(field_key) and field_key in @field_keys do
        %{
          "fieldKey" => field_key,
          "label" => normalize_optional_string(normalized["label"]) || humanize_field_key(field_key),
          "reason" => normalize_optional_string(normalized["reason"]),
          "preferredType" => preferred_field_type(field_key)
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(3)
  end

  defp prioritize_question_goals(spec, goals, missing_fields) do
    allowed_missing = MapSet.new(material_missing_fields(spec, missing_fields))
    allow_identity_questions = explicit_identity_request?(spec)

    goals
    |> normalize_question_goals()
    |> Enum.concat(
      Enum.map(material_missing_fields(spec, missing_fields), fn field ->
        %{
          "fieldKey" => field,
          "label" => humanize_field_key(field),
          "reason" => "Needed to finish the draft",
          "preferredType" => preferred_field_type(field)
        }
      end)
    )
    |> Enum.uniq_by(& &1["fieldKey"])
    |> Enum.filter(fn goal ->
      field_key = goal["fieldKey"]

      MapSet.member?(allowed_missing, field_key) or
        question_goal_allowed?(field_key, spec, allow_identity_questions)
    end)
    |> Enum.sort_by(fn goal ->
      question_priority(goal["fieldKey"], spec, allow_identity_questions)
    end, :desc)
    |> Enum.take(3)
  end

  defp material_missing_fields(spec, fields) do
    allow_identity_questions = explicit_identity_request?(spec)

    fields
    |> normalize_string_list()
    |> Enum.filter(&question_goal_allowed?(&1, spec, allow_identity_questions))
  end

  defp question_goal_allowed?(field_key, _spec, true) when field_key in @identity_question_fields,
    do: true

  defp question_goal_allowed?(field_key, _spec, false) when field_key in @identity_question_fields,
    do: false

  defp question_goal_allowed?("default_destination_chat_id", spec, _allow_identity_questions),
    do: requires_destination_chat?(spec)

  defp question_goal_allowed?(field_key, _spec, _allow_identity_questions) when is_binary(field_key),
    do: field_key in @field_keys

  defp question_goal_allowed?(_field_key, _spec, _allow_identity_questions), do: false

  defp question_priority(field_key, spec, allow_identity_questions) do
    base = Map.get(@question_priority, field_key, 50)

    cond do
      field_key == "default_destination_chat_id" and requires_destination_chat?(spec) -> base + 12
      field_key == "suggested_integrations" and integration_context?(spec) -> base + 10
      field_key == "enabled_tools" and tooling_context?(spec) -> base + 10
      field_key in @identity_question_fields and allow_identity_questions -> base + 40
      true -> base
    end
  end

  defp explicit_identity_request?(spec) do
    context =
      [
        get_in_string(spec, ["intent", "rawRequest"]),
        get_in_string(spec, ["intent", "businessSummary"])
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    Enum.any?(
      [
        "tone",
        "brand voice",
        "persona",
        "name this agent",
        "agent name",
        "username",
        "welcome message"
      ],
      &String.contains?(context, &1)
    )
  end

  defp requires_destination_chat?(spec) do
    missing_destination = blank?(get_in_string(spec, ["capabilities", "defaultDestinationChatId"]))

    missing_destination and
      (integration_context?(spec) or
         Enum.any?(get_in_string(spec, ["intent", "primaryJobs"]) || [], fn job ->
           String.contains?(String.downcase(to_string(job)), "update")
         end))
  end

  defp integration_context?(spec) do
    haystack =
      [
        get_in_string(spec, ["intent", "rawRequest"]),
        get_in_string(spec, ["intent", "businessSummary"]),
        Enum.join(get_in_string(spec, ["intent", "primaryJobs"]) || [], " "),
        Enum.join(get_in_string(spec, ["capabilities", "suggestedIntegrations"]) || [], " ")
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    Enum.any?(
      [
        "order",
        "trade",
        "ticket",
        "shipment",
        "alert",
        "event",
        "webhook",
        "integration",
        "notification",
        "update"
      ],
      &String.contains?(haystack, &1)
    )
  end

  defp tooling_context?(spec) do
    haystack =
      [
        get_in_string(spec, ["intent", "rawRequest"]),
        get_in_string(spec, ["intent", "businessSummary"]),
        Enum.join(get_in_string(spec, ["intent", "primaryJobs"]) || [], " "),
        Enum.join(get_in_string(spec, ["intent", "successCriteria"]) || [], " ")
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    Enum.any?(
      [
        "tool",
        "document",
        "doc",
        "pdf",
        "pricing",
        "price",
        "catalog",
        "inventory",
        "analysis",
        "analyze",
        "event",
        "crm",
        "order",
        "trade"
      ],
      &String.contains?(haystack, &1)
    )
  end

  defp suggested_integrations_missing?(spec, summary) do
    (get_in_string(spec, ["capabilities", "suggestedIntegrations"]) || []) == [] and
      Enum.any?(
        [
          "order",
          "trade",
          "ticket",
          "shipment",
          "alert",
          "document",
          "pricing",
          "catalog",
          "inventory",
          "crm"
        ],
        &String.contains?(summary, &1)
      )
  end

  defp enabled_tools_missing?(spec, summary) do
    (get_in_string(spec, ["capabilities", "enabledTools"]) || []) == [] and
      Enum.any?(
        [
          "create",
          "document",
          "analysis",
          "analyze",
          "summarize",
          "image",
          "voice",
          "event",
          "order",
          "trade"
        ],
        &String.contains?(summary, &1)
      )
  end

  defp blocked_actions_missing?(spec, summary) do
    (get_in_string(spec, ["autonomy", "blockedActions"]) || []) == [] and
      Enum.any?(
        [
          "refund",
          "cancel",
          "purchase",
          "approve",
          "message customers",
          "send messages",
          "trade",
          "order"
        ],
        &String.contains?(summary, &1)
      )
  end

  defp preferred_field_type("default_destination_chat_id"), do: "chat_picker"
  defp preferred_field_type("business_summary"), do: "long_text"
  defp preferred_field_type("business_type"), do: "single_select"
  defp preferred_field_type("system_prompt"), do: "long_text"
  defp preferred_field_type("welcome_message"), do: "long_text"
  defp preferred_field_type("blocked_actions"), do: "long_text"
  defp preferred_field_type("sample_prompts"), do: "long_text"
  defp preferred_field_type("expected_behaviors"), do: "long_text"
  defp preferred_field_type("display_name"), do: "text"
  defp preferred_field_type("username"), do: "text"
  defp preferred_field_type("persona"), do: "long_text"
  defp preferred_field_type("tone"), do: "single_select"
  defp preferred_field_type("autonomy_mode"), do: "single_select"
  defp preferred_field_type("output_modes"), do: "multi_select"
  defp preferred_field_type("enabled_tools"), do: "multi_select"
  defp preferred_field_type("suggested_integrations"), do: "multi_select"
  defp preferred_field_type("primary_jobs"), do: "multi_select"
  defp preferred_field_type("audience"), do: "multi_select"
  defp preferred_field_type(_field_key), do: "text"

  defp humanize_field_key(field_key) do
    field_key
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp looks_like_setup_request?(message) do
    normalized = String.downcase(message)

    Enum.any?(@setup_keywords, &String.contains?(normalized, &1)) ||
      semantic_setup_request?(normalized)
  end

  defp force_new_setup?(message) do
    normalized = String.downcase(message)

    Enum.any?(
      [
        "start over",
        "from scratch",
        "another agent",
        "new agent"
      ],
      &String.contains?(normalized, &1)
    )
  end

  defp explicit_legacy_intent?(message) do
    normalized = String.downcase(message)
    Enum.any?(@legacy_keywords, &String.contains?(normalized, &1))
  end

  defp semantic_setup_request?(normalized_message) do
    mentions_agent = String.contains?(normalized_message, "agent")

    has_setup_verb =
      Enum.any?(
        ["create", "build", "set up", "setup", "make", "draft", "configure", "new"],
        &String.contains?(normalized_message, &1)
      )

    has_runtime_context =
      Enum.any?(
        ["tool", "prompt", "event", "webhook", "integration", "env", "chat id", "chat", "document", "pricing", "trade", "order"],
        &String.contains?(normalized_message, &1)
      )

    (mentions_agent and has_setup_verb) ||
      (has_setup_verb and has_runtime_context and
         Enum.any?([" for my ", " for our ", "create me", "build me", "set me up"], &String.contains?(normalized_message, &1)))
  end

  defp summarize_active_agent(nil), do: nil

  defp summarize_active_agent(agent) do
    %{
      id: agent.id,
      display_name: agent.display_name,
      username: agent.agent_user && agent.agent_user.username,
      prompt_present: String.trim(agent.system_prompt || "") != "",
      enabled_tools: agent.enabled_tools || [],
      output_modes: agent.output_modes || [],
      autonomy_mode: agent.autonomy_mode
    }
  end

  defp recent_message_excerpt(messages) do
    messages
    |> List.wrap()
    |> Enum.take(-@max_recent_messages)
    |> Enum.map(fn message ->
      role =
        case message do
          %{"role" => value} -> value
          %{role: value} -> value
          _ -> "unknown"
        end

      content =
        case message do
          %{"content" => value} when is_binary(value) -> value
          %{content: value} when is_binary(value) -> value
          _ -> ""
        end

      %{"role" => role, "content" => String.slice(String.trim(content), 0, 400)}
    end)
  end

  defp normalize_answer_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, acc ->
      normalized_key = to_string(key)
      Map.put(acc, normalized_key, raw_value)
    end)
  end

  defp normalize_answer_map(_value), do: %{}

  defp normalize_ui_response(nil), do: nil

  defp normalize_ui_response(value) when is_map(value) do
    %{
      "requestId" => normalize_optional_string(value["requestId"] || value[:requestId]),
      "answers" => normalize_answer_map(value["answers"] || value[:answers] || %{})
    }
  end

  defp normalize_ui_response(_value), do: nil

  defp compose_spec_patch(worker_output) do
    %{}
    |> maybe_put("intent", normalize_map(worker_output["intent"]))
    |> maybe_put("identity", normalize_map(worker_output["identity"]))
    |> maybe_put("behavior", normalize_map(worker_output["behavior"]))
    |> maybe_put("confidence", normalize_confidence(worker_output["confidence"]))
  end

  defp normalize_section_summaries(section_summaries) do
    normalized = normalize_map(section_summaries)

    %{
      "identity" => normalize_optional_string(normalized["identity"]),
      "behavior" => normalize_optional_string(normalized["behavior"]),
      "tools" => normalize_optional_string(normalized["tools"]),
      "integrations" => normalize_optional_string(normalized["integrations"]),
      "autonomy" => normalize_optional_string(normalized["autonomy"]),
      "tests" => normalize_optional_string(normalized["tests"])
    }
  end

  defp normalize_tool_list(value) do
    value
    |> normalize_string_list()
    |> Enum.filter(&(&1 in ToolRegistry.tool_ids()))
    |> Enum.uniq()
    |> case do
      [] -> Agents.default_enabled_tools()
      tools -> tools
    end
  end

  defp normalize_output_modes(value) do
    value
    |> normalize_string_list()
    |> Enum.filter(&(&1 in ["text", "media", "voice"]))
    |> Enum.uniq()
    |> case do
      [] -> ["text"]
      modes -> modes
    end
  end

  defp normalize_autonomy_mode(value) do
    case normalize_optional_string(value) do
      "manual" -> "manual"
      "draft_first" -> "draft_first"
      "approval_required" -> "approval_required"
      "full_auto" -> "full_auto"
      "safe_auto" -> "safe_auto"
      _ -> "safe_auto"
    end
  end

  defp normalize_string_list_or_text(value) do
    case normalize_string_list(value) do
      [] ->
        case normalize_optional_string(value) do
          nil -> []
          text -> split_lines(text)
        end

      list ->
        list
    end
  end

  defp split_lines(text) do
    text
    |> to_string()
    |> String.split(~r/[\n,]/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.map(&normalize_optional_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(value) when is_binary(value) do
    split_lines(value)
  end

  defp normalize_string_list(_value), do: []

  defp normalize_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, inner_value}, acc ->
      Map.put(acc, to_string(key), inner_value)
    end)
  end

  defp normalize_map(_value), do: %{}

  defp normalize_confidence(value) when is_float(value), do: Float.round(min(max(value, 0.0), 1.0), 3)
  defp normalize_confidence(value) when is_integer(value), do: normalize_confidence(value / 100)
  defp normalize_confidence(_value), do: 0.0

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      "nil" -> nil
      "null" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_optional_string()
  defp normalize_optional_string(_value), do: nil

  defp normalize_ui_field_type(key, raw_type, options) do
    preferred = preferred_field_type(key)
    raw_type = normalize_optional_string(raw_type)
    has_options = List.wrap(options) != []

    cond do
      has_options and preferred in ["single_select", "multi_select"] ->
        preferred

      raw_type in ["single_select", "multi_select", "text", "long_text", "chat_picker"] ->
        raw_type

      true ->
        preferred
    end
  end

  defp blank?(value), do: is_nil(normalize_optional_string(value))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_string_path(map, _path, nil), do: map
  defp maybe_put_string_path(map, path, value), do: put_string_path(map, path, value)

  defp put_string_path(map, [key], value) do
    normalize_map(map)
    |> Map.put(key, value)
  end

  defp put_string_path(map, [key | rest], value) do
    normalized = normalize_map(map)
    current = normalize_map(normalized[key])
    Map.put(normalized, key, put_string_path(current, rest, value))
  end

  defp get_in_string(value, path) when is_list(path) do
    Enum.reduce_while(path, value, fn key, acc ->
      normalized = normalize_map(acc)

      case Map.get(normalized, key) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, normalize_map(right), fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp deep_merge(_left, right), do: normalize_map(right)

  defp object_schema(properties) do
    %{
      type: "object",
      properties: properties
    }
  end

  defp string_schema(nullable \\ false) do
    if nullable do
      %{type: "string"}
    else
      %{type: "string"}
    end
  end

  defp string_array_schema do
    %{
      type: "array",
      items: %{type: "string"}
    }
  end
end
