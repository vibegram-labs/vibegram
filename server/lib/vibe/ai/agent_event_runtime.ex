defmodule Vibe.AI.AgentEventRuntime do
  @moduledoc false

  import Ecto.Query, warn: false
  import Plug.Crypto, only: [secure_compare: 2]

  require Logger

  alias Decimal, as: D
  alias Vibe.Agent
  alias Vibe.AgentApprovalTask
  alias Vibe.AgentEvent
  alias Vibe.AgentEventThread
  alias Vibe.AgentIntegration
  alias Vibe.AgentRun
  alias Vibe.AgentRunbook
  alias Vibe.Agents
  alias Vibe.Chat
  alias Vibe.Chat.AgentMessageCrypto
  alias Vibe.Repo

  @safe_action_types ~w[post_message post_checklist request_confirmation set_thread_status]
  @high_priority_keywords ~w[failed failure blocked fraud urgent escalated chargeback liquidation stop_loss]

  def ingest(%Agent{} = agent, params, opts \\ []) when is_map(params) do
    secret = Keyword.get(opts, :secret)

    with {:ok, integration} <- resolve_integration(agent, params, secret),
         {:ok, normalized} <- normalize_event(agent, integration, params),
         :ok <- ensure_destination_chat(agent, normalized.destination_chat_id),
         {:ok, result} <- persist_event(agent, integration, normalized) do
      {:ok, result}
    end
  end

  def execute_approved_task(%Agent{} = agent, %AgentApprovalTask{} = task) do
    with %AgentEventThread{} = thread <- Repo.get(AgentEventThread, task.thread_id),
         {:ok, payload} <- execute_requested_action(agent, thread, task.requested_action || %{}, thread.root_message_id),
         {:ok, _thread} <-
           thread
           |> AgentEventThread.changeset(%{
             status: Map.get(payload, :thread_status, thread.status),
             last_decision: "approved_action"
           })
           |> Repo.update() do
      {:ok, payload}
    else
      nil -> {:error, :thread_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_event(%Agent{} = agent, integration, normalized) do
    existing =
      Repo.one(
        from e in AgentEvent,
          where:
            e.agent_id == ^agent.id and
              e.source == ^normalized.source and
              e.event_id == ^normalized.event_id,
          preload: [:thread]
      )

    case existing do
      %AgentEvent{} = event ->
        {:ok,
         %{
           success: true,
           duplicate: true,
           threadId: event.thread_id,
           eventId: event.id,
           decision: event.decision || "duplicate",
           status: event.status
         }}

      nil ->
        Repo.transaction(fn ->
          thread =
            upsert_thread!(
              agent,
              integration,
              normalized.source,
              normalized.thread_key,
              normalized.destination_chat_id,
              normalized.title,
              normalized.payload,
              normalized.occurred_at
            )

          last_event = latest_thread_event(thread.id)
          runbook = matching_runbook(agent, integration, normalized.event_type)
          policy = evaluate_policy(agent, integration, normalized, last_event, runbook)

          event =
            %AgentEvent{}
            |> AgentEvent.changeset(%{
              agent_id: agent.id,
              integration_id: integration && integration.id,
              thread_id: thread.id,
              event_id: normalized.event_id,
              event_type: normalized.event_type,
              source: normalized.source,
              title: normalized.title,
              text: normalized.text,
              attachments: normalized.attachments,
              payload: normalized.payload,
              occurred_at: normalized.occurred_at,
              status: initial_event_status(policy.mode),
              decision: policy.mode,
              decision_reason: policy.reason
            })
            |> Repo.insert!()

          {thread, event, message_payload} =
            case policy.post_event_message? do
              true ->
                {:ok, message_payload} = post_event_message(agent, thread, event, normalized, policy)
                updated_event =
                  event
                  |> AgentEvent.changeset(%{message_id: message_payload.message_id})
                  |> Repo.update!()

                updated_thread =
                  if is_nil(thread.root_message_id) do
                    thread
                    |> AgentEventThread.changeset(%{root_message_id: message_payload.message_id})
                    |> Repo.update!()
                  else
                    thread
                  end

                {updated_thread, updated_event, message_payload}

              false ->
                {thread, event, nil}
            end

          summary = build_summary(thread.summary, normalized, policy)
          current_state = next_thread_state(thread.current_state || %{}, normalized, policy)

          updated_thread =
            thread
            |> AgentEventThread.changeset(%{
              title: normalized.title || thread.title,
              summary: summary,
              current_state: current_state,
              priority: policy.priority,
              last_decision: policy.mode,
              latest_event_at: normalized.occurred_at
            })
            |> Repo.update!()

          result =
            case policy.mode do
              "act" ->
                execute_runbook(agent, integration, updated_thread, event, runbook, normalized, policy)

              "approval_required" ->
                create_approval(agent, integration, updated_thread, event, runbook, normalized, policy)

              _ ->
                {:ok,
                 %{
                   status: initial_event_status(policy.mode),
                   run: create_run!(agent, integration, updated_thread, event, runbook, policy, %{}),
                   message: message_payload
                 }}
            end

          integration && touch_integration!(integration)

          case result do
            {:ok, details} ->
              %{
                success: true,
                duplicate: false,
                threadId: updated_thread.id,
                eventId: event.id,
                decision: policy.mode,
                priority: policy.priority,
                status: details.status || initial_event_status(policy.mode),
                messagePosted: message_payload != nil,
                rootMessageId: updated_thread.root_message_id,
                runId: details.run && details.run.id,
                approvalTaskId: details[:approval_task] && details.approval_task.id
              }

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)
        |> case do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp resolve_integration(%Agent{} = agent, params, secret) do
    requested_id = normalize_string(params["integrationId"] || params["integration_id"])

    integration =
      case requested_id do
        nil -> nil
        integration_id -> Agents.get_integration(agent, integration_id)
      end

    cond do
      not is_binary(secret) ->
        {:error, :invalid_secret}

      match?(%AgentIntegration{}, integration) and verify_integration_secret(integration, secret) ->
        {:ok, integration}

      match?(%AgentIntegration{}, integration) and Agents.verify_secret(agent, secret) ->
        {:ok, integration}

      match?(%AgentIntegration{}, integration) ->
        {:error, :invalid_secret}

      matched = Agents.find_integration_by_secret(agent, secret) ->
        {:ok, matched}

      Agents.verify_secret(agent, secret) ->
        {:ok, nil}

      true ->
        {:error, :invalid_secret}
    end
  end

  defp normalize_event(%Agent{} = agent, integration, params) do
    event_type = normalize_string(params["eventType"] || params["event_type"])
    source = normalize_string(params["source"]) || (integration && integration.source_type) || "internal"
    title = normalize_string(params["title"])
    text = normalize_string(params["text"] || params["message"])
    payload = normalize_payload(params["data"] || params["payload"])
    occurred_at = parse_datetime(params["timestamp"]) || DateTime.utc_now()

    event_id =
      normalize_string(params["eventId"] || params["event_id"])
      || build_fingerprint(source, title, text, occurred_at, payload)

    thread_key =
      normalize_string(params["threadKey"] || params["thread_key"])
      || normalize_string(payload["thread_key"])
      || normalize_string(payload["order_id"])
      || normalize_string(payload["trade_id"])
      || event_id

    destination_chat_id =
      normalize_string(params["destinationChatId"] || params["destination_chat_id"])
      || (integration && integration.default_destination_chat_id)
      || agent.default_destination_chat_id

    cond do
      is_nil(event_type) ->
        {:error, :missing_event_type}

      is_nil(destination_chat_id) ->
        {:error, :missing_destination_chat}

      true ->
        {:ok,
         %{
           event_id: event_id,
           event_type: event_type,
           source: source,
           title: title || humanize_event_type(event_type),
           text: text,
           payload: payload,
           attachments: normalize_attachments(params["attachments"]),
           occurred_at: occurred_at,
           thread_key: thread_key,
           destination_chat_id: destination_chat_id
         }}
    end
  end

  defp ensure_destination_chat(%Agent{} = agent, chat_id) do
    if Chat.is_participant?(chat_id, agent.agent_user_id), do: :ok, else: {:error, :chat_not_attached}
  end

  defp upsert_thread!(agent, integration, source, thread_key, chat_id, title, payload, occurred_at) do
    existing =
      Repo.one(
        from t in AgentEventThread,
          where: t.agent_id == ^agent.id and t.source == ^source and t.thread_key == ^thread_key
      )

    attrs = %{
      agent_id: agent.id,
      integration_id: integration && integration.id,
      chat_id: chat_id,
      source: source,
      thread_key: thread_key,
      title: title,
      latest_event_at: occurred_at,
      current_state: payload
    }

    case existing do
      nil ->
        %AgentEventThread{}
        |> AgentEventThread.changeset(attrs)
        |> Repo.insert!()

      %AgentEventThread{} = thread ->
        thread
        |> AgentEventThread.changeset(%{
          integration_id: integration && integration.id || thread.integration_id,
          chat_id: chat_id,
          title: title || thread.title,
          latest_event_at: occurred_at
        })
        |> Repo.update!()
    end
  end

  defp latest_thread_event(thread_id) do
    Repo.one(
      from e in AgentEvent,
        where: e.thread_id == ^thread_id,
        order_by: [desc: e.occurred_at, desc: e.inserted_at],
        limit: 1
    )
  end

  defp evaluate_policy(agent, integration, normalized, last_event, runbook) do
    priority = classify_priority(normalized)
    autonomy = effective_autonomy(agent, integration)
    estimated_cost_cents = estimated_cost_cents(runbook)

    cond do
      not event_type_enabled?(agent, integration, normalized.event_type) ->
        %{
          mode: "log_only",
          priority: priority,
          reason: "event_type_disabled",
          post_event_message?: false,
          estimated_cost_cents: 0
        }

      noise_duplicate?(normalized, last_event) ->
        %{
          mode: "log_only",
          priority: priority,
          reason: "noise_suppressed",
          post_event_message?: false,
          estimated_cost_cents: 0
        }

      budget_exceeded?(agent, integration, estimated_cost_cents) ->
        %{
          mode: if(runbook, do: "approval_required", else: "log_only"),
          priority: priority,
          reason: "budget_exceeded",
          post_event_message?: true,
          estimated_cost_cents: estimated_cost_cents
        }

      match?(%AgentRunbook{}, runbook) and auto_executable?(autonomy, runbook) ->
        %{
          mode: "act",
          priority: priority,
          reason: "matching_runbook",
          post_event_message?: true,
          estimated_cost_cents: estimated_cost_cents
        }

      match?(%AgentRunbook{}, runbook) ->
        %{
          mode: "approval_required",
          priority: priority,
          reason: "runbook_requires_approval",
          post_event_message?: true,
          estimated_cost_cents: estimated_cost_cents
        }

      true ->
        %{
          mode: "summarize",
          priority: priority,
          reason: "summary_only",
          post_event_message?: true,
          estimated_cost_cents: estimated_cost_cents
        }
    end
  end

  defp event_type_enabled?(agent, integration, event_type) do
    integration_enabled = integration && List.wrap(integration.event_types_enabled)
    agent_enabled = List.wrap(agent.event_types_enabled)

    enabled =
      case integration_enabled do
        list when is_list(list) and list != [] -> list
        _ -> agent_enabled
      end

    enabled == [] or event_type in enabled
  end

  defp classify_priority(normalized) do
    searchable =
      [
        normalized.event_type,
        normalized.title,
        normalized.text,
        inspect(normalized.payload)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      Enum.any?(@high_priority_keywords, &String.contains?(searchable, &1)) -> "urgent"
      String.contains?(searchable, "refund") or String.contains?(searchable, "failed") -> "high"
      true -> "normal"
    end
  end

  defp effective_autonomy(agent, %AgentIntegration{} = integration), do: integration.autonomy_mode || agent.autonomy_mode
  defp effective_autonomy(agent, _integration), do: agent.autonomy_mode || "safe_auto"

  defp auto_executable?(autonomy, %AgentRunbook{} = runbook) do
    runbook.enabled &&
      runbook.action_type in @safe_action_types &&
      case autonomy do
        "full_auto" -> runbook.risk_level in ["low", "medium"]
        _ -> runbook.risk_level == "low"
      end
  end

  defp budget_exceeded?(agent, integration, estimated_cost_cents) do
    daily_budget = (integration && integration.cost_budget_daily) || agent.cost_budget_daily
    monthly_budget = (integration && integration.cost_budget_monthly) || agent.cost_budget_monthly

    cond do
      is_integer(daily_budget) and daily_budget >= 0 and today_cost_cents(agent, integration) + estimated_cost_cents > daily_budget ->
        true

      is_integer(monthly_budget) and monthly_budget >= 0 and month_cost_cents(agent, integration) + estimated_cost_cents > monthly_budget ->
        true

      true ->
        false
    end
  end

  defp today_cost_cents(agent, integration) do
    since = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    run_cost_cents(agent, integration, since)
  end

  defp month_cost_cents(agent, integration) do
    today = Date.utc_today()
    since = Date.new!(today.year, today.month, 1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    run_cost_cents(agent, integration, since)
  end

  defp run_cost_cents(agent, integration, since) do
    integration_id = integration && integration.id

    query =
      from r in AgentRun,
        where: r.agent_id == ^agent.id and r.inserted_at >= ^since,
        select: r.cost_usd

    query =
      if is_binary(integration_id) do
        from r in query, where: r.integration_id == ^integration_id
      else
        query
      end

    Repo.all(query)
    |> Enum.reduce(0, fn
      %D{} = amount, acc ->
        cents =
          amount
          |> D.mult(D.new(100))
          |> D.round(0)
          |> D.to_string()
          |> String.to_integer()

        acc + cents

      _amount, acc ->
        acc
    end)
  end

  defp estimated_cost_cents(nil), do: 1
  defp estimated_cost_cents(%AgentRunbook{action_type: "post_message"}), do: 3
  defp estimated_cost_cents(%AgentRunbook{action_type: "request_confirmation"}), do: 3
  defp estimated_cost_cents(%AgentRunbook{}), do: 5

  defp build_summary(previous_summary, normalized, policy) do
    headline =
      [normalized.title, normalized.text]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(": ")
      |> String.trim()

    latest =
      if headline == "" do
        "#{humanize_event_type(normalized.event_type)} in #{normalized.thread_key}"
      else
        headline
      end

    case normalize_string(previous_summary) do
      nil -> "[#{String.upcase(policy.priority)}] #{latest}"
      summary -> "#{summary}\nLatest: #{latest}"
    end
  end

  defp next_thread_state(current_state, normalized, policy) do
    current_state
    |> Map.merge(normalized.payload)
    |> Map.put("last_event_type", normalized.event_type)
    |> Map.put("last_event_text", normalized.text)
    |> Map.put("last_event_title", normalized.title)
    |> Map.put("last_event_at", DateTime.to_iso8601(normalized.occurred_at))
    |> Map.put("priority", policy.priority)
  end

  defp execute_runbook(agent, integration, thread, event, runbook, normalized, policy) do
    with {:ok, action_payload} <- runbook_action_payload(normalized, runbook),
         {:ok, execution} <- execute_requested_action(agent, thread, action_payload, thread.root_message_id),
         {:ok, _event} <-
           event
           |> AgentEvent.changeset(%{status: "acted"})
           |> Repo.update(),
         {:ok, _thread} <-
           thread
           |> AgentEventThread.changeset(%{
             status: Map.get(execution, :thread_status, thread.status),
             last_decision: "act"
           })
           |> Repo.update() do
      run =
        create_run!(agent, integration, thread, event, runbook, policy, %{
          result: %{
            action: action_payload,
            execution: execution
          }
        })

      {:ok, %{status: "acted", run: run}}
    end
  end

  defp create_approval(agent, integration, thread, event, runbook, normalized, policy) do
    requested_action =
      case runbook_action_payload(normalized, runbook) do
        {:ok, payload} -> payload
        {:error, _} -> fallback_requested_action(normalized)
      end

    task =
      %AgentApprovalTask{}
      |> AgentApprovalTask.changeset(%{
        agent_id: agent.id,
        thread_id: thread.id,
        event_id: event.id,
        runbook_id: runbook && runbook.id,
        chat_id: thread.chat_id,
        requested_action: requested_action,
        rationale: "Approval required for #{normalized.event_type}",
        status: "pending"
      })
      |> Repo.insert!()

    _ =
      post_system_followup(
        agent,
        thread,
        "Approval needed for #{normalized.title || normalized.event_type}. Open the task to approve or reject.",
        %{
          "approvalTaskId" => task.id,
          "eventThreadId" => thread.id,
          "eventId" => event.id,
          "status" => "pending_approval"
        }
      )

    run =
      create_run!(agent, integration, thread, event, runbook, policy, %{
        result: %{
          approvalTaskId: task.id,
          requestedAction: requested_action
        }
      })

    {:ok, %{status: "approval_required", run: run, approval_task: task}}
  end

  defp runbook_action_payload(normalized, %AgentRunbook{} = runbook) do
    title = normalized.title || humanize_event_type(normalized.event_type)
    config = runbook.action_config || %{}
    action_type = runbook.action_type || "post_message"

    payload =
      %{
        "actionType" => action_type,
        "title" => Map.get(config, "title") || title,
        "message" =>
          Map.get(config, "message")
          || runbook.instructions
          || fallback_action_message(normalized)
      }

    payload =
      case Map.get(config, "items") do
        items when is_list(items) -> Map.put(payload, "items", items)
        _ -> payload
      end

    payload =
      case Map.get(config, "status") do
        status when is_binary(status) -> Map.put(payload, "status", status)
        _ -> payload
      end

    {:ok, payload}
  end

  defp runbook_action_payload(_normalized, _runbook), do: {:error, :missing_runbook}

  defp fallback_requested_action(normalized) do
    %{
      "actionType" => "post_message",
      "title" => "Review #{normalized.event_type}",
      "message" => fallback_action_message(normalized)
    }
  end

  defp fallback_action_message(normalized) do
    [
      "Review #{normalized.title || humanize_event_type(normalized.event_type)}.",
      normalize_string(normalized.text)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp execute_requested_action(agent, thread, requested_action, reply_to_id) do
    action_type = requested_action["actionType"] || requested_action["action_type"] || "post_message"
    title = normalize_string(requested_action["title"])
    message = normalize_string(requested_action["message"])

    case action_type do
      "post_message" ->
        post_system_followup(agent, thread, join_title_and_body(title, message), %{
          "actionType" => action_type,
          "threadId" => thread.id
        })

      "request_confirmation" ->
        post_system_followup(
          agent,
          thread,
          join_title_and_body(title, message || "Please confirm the next step."),
          %{"actionType" => action_type, "threadId" => thread.id}
        )

      "post_checklist" ->
        checklist =
          requested_action["items"]
          |> List.wrap()
          |> Enum.map(&normalize_string/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map_join("\n", &"- #{&1}")

        post_system_followup(
          agent,
          thread,
          [title, message, checklist] |> Enum.reject(&is_nil/1) |> Enum.join("\n"),
          %{"actionType" => action_type, "threadId" => thread.id}
        )

      "set_thread_status" ->
        {:ok, %{thread_status: normalize_string(requested_action["status"]) || "in_progress"}}

      other ->
        {:error, {:unsupported_action, other, reply_to_id}}
    end
  end

  defp create_run!(agent, integration, thread, event, runbook, policy, extra) do
    cost_usd =
      policy.estimated_cost_cents
      |> D.new()
      |> D.div(D.new(100))

    %AgentRun{}
    |> AgentRun.changeset(%{
      agent_id: agent.id,
      integration_id: integration && integration.id,
      thread_id: thread.id,
      event_id: event.id,
      runbook_id: runbook && runbook.id,
      trigger: "event_ingestion",
      mode: policy.mode,
      model: if(policy.mode == "summarize", do: "rule+template", else: "runbook"),
      prompt_version: "event_threads_v1",
      decision: policy.reason,
      audit_summary: "#{policy.mode}: #{policy.reason}",
      result: Map.get(extra, :result, %{}),
      tool_calls: %{"items" => []},
      status: "completed",
      cost_usd: cost_usd
    })
    |> Repo.insert!()
  end

  defp post_event_message(agent, thread, event, normalized, policy) do
    body =
      [
        normalized.title || humanize_event_type(normalized.event_type),
        normalize_string(normalized.text),
        summarize_payload_line(normalized.payload)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    metadata = %{
      "eventThread" => true,
      "eventThreadId" => thread.id,
      "eventId" => event.id,
      "threadKey" => thread.thread_key,
      "eventType" => normalized.event_type,
      "source" => normalized.source,
      "priority" => policy.priority,
      "decision" => policy.mode,
      "payload" => normalized.payload,
      "attachments" => normalize_attachments_payload(normalized.attachments)
    }

    with {:ok, primary_message} <-
           maybe_post_event_summary(agent, thread.chat_id, body, metadata, thread.root_message_id),
         {:ok, _attachment_messages} <-
           post_event_attachments(
             agent,
             thread.chat_id,
             normalize_attachments_payload(normalized.attachments),
             metadata,
             primary_message && primary_message.message_id || thread.root_message_id
           ) do
      {:ok, primary_message}
    end
  end

  defp post_system_followup(agent, thread, body, metadata) do
    post_chat_message(
      agent,
      thread.chat_id,
      body,
      Map.put(metadata, "eventThreadId", thread.id),
      thread.root_message_id
    )
  end

  defp post_chat_message(agent, chat_id, body, metadata, reply_to_id) do
    post_chat_message(agent, chat_id, body, metadata, reply_to_id, [])
  end

  defp post_chat_message(agent, chat_id, body, metadata, reply_to_id, opts) do
    message_id = Ecto.UUID.generate()
    timestamp = System.system_time(:millisecond)
    message_type = Keyword.get(opts, :type, "text")
    media_url = Keyword.get(opts, :media_url)

    metadata =
      metadata
      |> maybe_put("fileName", normalize_string(metadata["fileName"] || metadata[:fileName]))
      |> maybe_put("fileSize", normalize_integer(metadata["fileSize"] || metadata[:fileSize]))
      |> maybe_put("duration", normalize_number(metadata["duration"] || metadata[:duration]))
      |> maybe_put("mimeType", normalize_string(metadata["mimeType"] || metadata[:mimeType]))
      |> maybe_put("caption", normalize_string(metadata["caption"] || metadata[:caption]))
      |> maybe_put("isVideoNote", normalize_boolean(metadata["isVideoNote"] || metadata[:isVideoNote]))

    attrs =
      %{
        id: message_id,
        chat_id: chat_id,
        from_id: agent.agent_user_id,
        encrypted_content: AgentMessageCrypto.encrypt_for_storage(body || ""),
        type: message_type,
        media_url: media_url,
        metadata:
          metadata
          |> Map.put("isAgentMessage", true)
          |> Map.put("agentName", agent.display_name)
          |> Map.put("agentId", agent.id),
        reply_to_id: reply_to_id,
        timestamp: timestamp
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Chat.add_message(attrs, acting_user_id: agent.agent_user_id) do
      {:ok, _message} ->
        payload = %{
          "id" => message_id,
          "fromId" => agent.agent_user_id,
          "chatId" => chat_id,
          "encryptedContent" => "",
          "plainContent" => body,
          "plaintext" => body,
          "type" => message_type,
          "mediaUrl" => media_url,
          "fileName" => metadata["fileName"],
          "fileSize" => metadata["fileSize"],
          "duration" => metadata["duration"],
          "caption" => metadata["caption"] || normalize_string(body),
          "isVideoNote" => metadata["isVideoNote"],
          "timestamp" => timestamp,
          "status" => "sent",
          "isAgentMessage" => true,
          "agentName" => agent.display_name,
          "agentId" => agent.id,
          "metadata" => attrs.metadata,
          "replyToId" => reply_to_id
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

        VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "message", payload)

        Chat.get_all_participant_settings(chat_id)
        |> Enum.each(fn participant ->
          if participant.user_id != agent.agent_user_id do
            VibeWeb.Endpoint.broadcast!("user:#{participant.user_id}", "new_message", %{
              chat_id: chat_id,
              from_id: agent.agent_user_id,
              message_id: message_id,
              timestamp: timestamp,
              muted: participant.muted || false
            })
          end
        end)

        {:ok, %{message_id: message_id, timestamp: timestamp}}

      error ->
        error
    end
  end

  defp maybe_post_event_summary(agent, chat_id, body, metadata, reply_to_id) do
    if normalize_string(body) do
      post_chat_message(agent, chat_id, body, metadata, reply_to_id)
    else
      {:ok, nil}
    end
  end

  defp post_event_attachments(_agent, _chat_id, [], _metadata, _reply_to_id), do: {:ok, []}

  defp post_event_attachments(agent, chat_id, attachments, metadata, reply_to_id) do
    attachments
    |> Enum.reduce_while({:ok, []}, fn attachment, {:ok, acc} ->
      attachment_metadata =
        metadata
        |> Map.put("attachment", attachment)
        |> maybe_put("fileName", normalize_string(attachment["name"] || attachment[:name]))
        |> maybe_put("fileSize", normalize_integer(attachment["fileSize"] || attachment[:fileSize]))
        |> maybe_put("duration", normalize_number(attachment["duration"] || attachment[:duration]))
        |> maybe_put("mimeType", normalize_string(attachment["mimeType"] || attachment[:mimeType]))
        |> maybe_put("isVideoNote", normalize_boolean(attachment["isVideoNote"] || attachment[:isVideoNote]))
        |> maybe_put("caption", normalize_string(attachment["caption"] || attachment[:caption]))

      caption =
        normalize_string(
          attachment["caption"] || attachment[:caption] || attachment["text"] || attachment[:text]
        ) || ""

      case post_chat_message(
             agent,
             chat_id,
             caption,
             attachment_metadata,
             reply_to_id,
             type: attachment_message_type(attachment),
             media_url: attachment["url"]
           ) do
        {:ok, message_payload} ->
          {:cont, {:ok, acc ++ [message_payload]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp touch_integration!(%AgentIntegration{} = integration) do
    integration
    |> AgentIntegration.changeset(%{last_event_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  defp matching_runbook(agent, integration, event_type) do
    integration_id = integration && integration.id

    Repo.all(
      from r in AgentRunbook,
        where: r.agent_id == ^agent.id and r.enabled == true,
        where: is_nil(r.integration_id) or r.integration_id == ^integration_id,
        order_by: [desc: r.integration_id, asc: r.inserted_at]
    )
    |> Enum.find(fn runbook ->
      types = List.wrap(runbook.event_types_enabled)
      types == [] or event_type in types
    end)
  end

  defp verify_integration_secret(%AgentIntegration{} = integration, secret) when is_binary(secret) do
    secure_compare(hash_secret(secret), integration.secret_hash || "")
  end

  defp verify_integration_secret(_integration, _secret), do: false

  defp hash_secret(secret) do
    :crypto.hash(:sha256, secret)
    |> Base.encode16(case: :lower)
  end

  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp normalize_payload(value) when is_map(value) do
    value
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_payload(_), do: %{}

  defp normalize_attachments(value) when is_list(value) do
    items =
      Enum.map(value, fn item ->
        %{
          "type" => normalize_string(item["type"] || item[:type]),
          "url" => normalize_string(item["url"] || item[:url] || item["mediaUrl"] || item[:mediaUrl]),
          "name" =>
            normalize_string(item["name"] || item[:name] || item["fileName"] || item[:fileName]),
          "mimeType" =>
            normalize_string(
              item["mimeType"] || item[:mimeType] || item["mime_type"] || item[:mime_type]
            ),
          "caption" => normalize_string(item["caption"] || item[:caption]),
          "duration" => normalize_number(item["duration"] || item[:duration]),
          "fileSize" =>
            normalize_integer(
              item["fileSize"] || item[:fileSize] || item["file_size"] || item[:file_size]
            ),
          "isVideoNote" =>
            normalize_boolean(
              item["isVideoNote"] || item[:isVideoNote] || item["is_video_note"] ||
                item[:is_video_note]
            )
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()
      end)
      |> Enum.filter(&is_binary(&1["url"]))

    %{"items" => items}
  end

  defp normalize_attachments(_), do: %{"items" => []}

  defp normalize_attachments_payload(%{"items" => items}) when is_list(items), do: items
  defp normalize_attachments_payload(_), do: []

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_string()
  defp normalize_string(_), do: nil

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_float(value) do
    if finite_number?(value), do: round(value), else: nil
  end

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp normalize_integer(_), do: nil

  defp normalize_number(value) when is_integer(value), do: value * 1.0

  defp normalize_number(value) when is_float(value) do
    if finite_number?(value), do: value, else: nil
  end

  defp normalize_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp normalize_number(_), do: nil

  defp normalize_boolean(value) when value in [true, false], do: value
  defp normalize_boolean(value) when value in ["true", "1", 1], do: true
  defp normalize_boolean(value) when value in ["false", "0", 0], do: false
  defp normalize_boolean(_), do: nil

  defp finite_number?(value) when is_float(value), do: value == value

  defp attachment_message_type(attachment) when is_map(attachment) do
    explicit =
      normalize_string(
        attachment["messageType"] || attachment[:messageType] || attachment["message_type"] ||
          attachment[:message_type] || attachment["type"] || attachment[:type]
      )
      |> normalize_attachment_type()

    explicit || infer_attachment_message_type(attachment)
  end

  defp attachment_message_type(_attachment), do: "file"

  defp normalize_attachment_type(type) do
    case normalize_string(type) do
      "image" -> "image"
      "gif" -> "gif"
      "video" -> "video"
      "video_note" -> "video"
      "voice" -> "voice"
      "audio" -> "music"
      "music" -> "music"
      "mp3" -> "music"
      "file" -> "file"
      "document" -> "file"
      _ -> nil
    end
  end

  defp infer_attachment_message_type(attachment) do
    mime_type = normalize_string(attachment["mimeType"] || attachment[:mimeType]) || ""
    url = normalize_string(attachment["url"] || attachment[:url]) || ""
    lowered_mime = String.downcase(mime_type)
    lowered_url = String.downcase(url)

    cond do
      String.starts_with?(lowered_mime, "image/gif") or String.match?(lowered_url, ~r/\.gif(\?|$)/) ->
        "gif"

      String.starts_with?(lowered_mime, "image/") or
          String.match?(lowered_url, ~r/\.(png|jpe?g|webp|heic|bmp)(\?|$)/) ->
        "image"

      String.starts_with?(lowered_mime, "video/") or
          String.match?(lowered_url, ~r/\.(mp4|mov|m4v|webm|mkv)(\?|$)/) ->
        "video"

      String.starts_with?(lowered_mime, "audio/") or
          String.match?(lowered_url, ~r/\.(mp3|m4a|aac|wav|ogg|oga|flac)(\?|$)/) ->
        "music"

      true ->
        "file"
    end
  end

  defp build_fingerprint(source, title, text, occurred_at, payload) do
    [
      source,
      title,
      text,
      DateTime.to_iso8601(occurred_at),
      Jason.encode!(payload)
    ]
    |> Enum.join("|")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp humanize_event_type(event_type) do
    event_type
    |> to_string()
    |> String.replace(".", " ")
    |> String.replace("_", " ")
    |> String.trim()
    |> String.capitalize()
  end

  defp summarize_payload_line(payload) when map_size(payload) == 0, do: nil

  defp summarize_payload_line(payload) do
    payload
    |> Enum.take(4)
    |> Enum.map_join(" | ", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp join_title_and_body(nil, nil), do: ""
  defp join_title_and_body(title, nil), do: title
  defp join_title_and_body(nil, body), do: body
  defp join_title_and_body(title, body), do: "#{title}\n#{body}"

  defp noise_duplicate?(normalized, %AgentEvent{} = last_event) do
    same_shape? =
      last_event.event_type == normalized.event_type and
        normalize_string(last_event.title) == normalized.title and
        normalize_string(last_event.text) == normalized.text

    occurred_delta =
      case last_event.occurred_at do
        %DateTime{} = dt -> abs(DateTime.diff(normalized.occurred_at, dt, :second))
        _ -> 999_999
      end

    same_shape? and occurred_delta <= 300
  end

  defp noise_duplicate?(_normalized, _last_event), do: false

  defp initial_event_status("act"), do: "acted"
  defp initial_event_status("approval_required"), do: "approval_required"
  defp initial_event_status("summarize"), do: "summarized"
  defp initial_event_status(_), do: "logged"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
