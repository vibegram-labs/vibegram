defmodule Vibe.AI.SubagentRegistry do
  @moduledoc false

  alias Vibe.AI.Agent, as: ChatAgent
  alias Vibe.AI.AgentBuilder

  @subagents %{
    "builder_assistant" => %{
      id: "builder_assistant",
      label: "Builder Assistant",
      description: "Creates, updates, publishes, and explains Vibe standalone agents."
    },
    "integration_advisor" => %{
      id: "integration_advisor",
      label: "Integration Advisor",
      description: "Prepares invoke URLs, events URLs, chat ids, and agent integration guidance."
    },
    "music_specialist" => %{
      id: "music_specialist",
      label: "Music Specialist",
      description: "Handles music discovery and playback related tasks."
    },
    "document_specialist" => %{
      id: "document_specialist",
      label: "Document Specialist",
      description: "Handles document, web, and image analysis tasks."
    }
  }

  def specs do
    @subagents
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  def ids do
    Enum.map(specs(), & &1.id)
  end

  def get(id) when is_binary(id), do: Map.get(@subagents, id)
  def get(_id), do: nil

  def progress_label(id, task) do
    request = task |> to_string() |> String.trim()

    cond do
      request == "" ->
        fallback_progress_label(id)

      true ->
        request
        |> summarize_task_label()
        |> case do
          nil -> fallback_progress_label(id)
          label -> label
        end
    end
  end

  def run(id, task, opts \\ []) do
    request =
      task
      |> to_string()
      |> String.trim()

    callback = Keyword.get(opts, :callback)
    user_id = Keyword.get(opts, :user_id)
    chat_id = Keyword.get(opts, :chat_id)

    with %{} = spec <- get(id),
         true <- request != "" do
      job_label = progress_label(id, request)

      emit(callback, %{
        type: :subagent,
        event: "started",
        subagent: spec.id,
        label: spec.label,
        detail: job_label,
        status: "running"
      })

      emit(callback, %{
        type: :subagent,
        event: "progress",
        subagent: spec.id,
        label: spec.label,
        detail: job_label,
        status: "running"
      })

      result =
        case id do
          "builder_assistant" ->
            AgentBuilder.delegate_task(user_id, request, callback: wrap_callback(spec, callback))

          "integration_advisor" ->
            AgentBuilder.delegate_task(
              user_id,
              "Help with agent integration details, endpoints, ids, auth, and attached vibe chat ids. #{request}",
              callback: wrap_callback(spec, callback)
            )

          "music_specialist" ->
            run_chat_subagent(
              request,
              spec,
              wrap_callback(spec, callback),
              user_id,
              chat_id,
              "You are the music specialist for Vibe AI. Focus only on music discovery and playback tasks. Use the smallest response necessary.",
              ["search_music"]
            )

          "document_specialist" ->
            run_chat_subagent(
              request,
              spec,
              wrap_callback(spec, callback),
              user_id,
              chat_id,
              "You are the document and research specialist for Vibe AI. Focus on search, image analysis, and document analysis. Use the smallest response necessary.",
              ["search_google", "analyze_image", "analyze_document"]
            )
        end

      finalize_result(result, spec, callback)
    else
      nil -> {:error, :unknown_subagent}
      false -> {:error, :missing_task}
    end
  end

  defp run_chat_subagent(task, spec, callback, user_id, chat_id, system_prompt, enabled_tools) do
    case ChatAgent.stream_response(
           task,
           callback,
           user_id: user_id,
           chat_id: chat_id,
           system_prompt: system_prompt,
           enabled_tools: enabled_tools
         ) do
      {:ok, reply} ->
        {:ok, %{reply: reply, metadata: %{"subagent" => spec.id}}}

      error ->
        error
    end
  end

  defp finalize_result({:ok, %{reply: reply} = result}, spec, callback) do
    emit(callback, %{
      type: :subagent,
      event: "finished",
      subagent: spec.id,
      label: spec.label,
      status: "complete"
    })

    {:ok,
     %{
       "ok" => true,
       "subagent_id" => spec.id,
       "label" => spec.label,
       "response" => to_string(reply || "") |> String.trim(),
       "metadata" => Map.get(result, :metadata) || Map.get(result, "metadata") || %{}
     }}
  end

  defp finalize_result({:error, reason}, spec, callback) do
    emit(callback, %{
      type: :subagent,
      event: "finished",
      subagent: spec.id,
      label: spec.label,
      status: "error",
      error: inspect(reason)
    })

    {:ok,
     %{
       "ok" => false,
       "subagent_id" => spec.id,
       "label" => spec.label,
       "error" => inspect(reason)
     }}
  end

  defp wrap_callback(spec, callback) when is_function(callback, 1) do
    fn
      %{type: :progress, label: label} = event ->
        callback.(%{
          type: :subagent,
          event: "progress",
          subagent: spec.id,
          label: spec.label,
          detail: label,
          tool: Map.get(event, :tool),
          status: Map.get(event, :status)
        })

      %{type: :tool_result, tool: tool_name} ->
        callback.(%{
          type: :subagent,
          event: "tool_result",
          subagent: spec.id,
          label: spec.label,
          tool: tool_name
        })

      %{type: :text} ->
        :ok

      _ ->
        :ok
    end
  end

  defp wrap_callback(_spec, _callback), do: fn _event -> :ok end

  defp emit(callback, payload) when is_function(callback, 1), do: callback.(payload)
  defp emit(_callback, _payload), do: :ok

  defp summarize_task_label(task) do
    trimmed =
      task
      |> String.trim()
      |> String.replace(~r/\s+/, " ")
      |> String.trim_trailing(".")

    case Regex.run(~r/^\s*(check|find|get|read|list|review|show|look up|inspect|prepare|create|update|publish|rotate|generate|explain|analyze|search)\b\s*(.*)$/i, trimmed) do
      [_, verb, rest] ->
        job =
          case String.downcase(verb) do
            "check" -> "Checking"
            "find" -> "Finding"
            "get" -> "Getting"
            "read" -> "Reading"
            "list" -> "Listing"
            "review" -> "Reviewing"
            "show" -> "Reviewing"
            "look up" -> "Looking up"
            "inspect" -> "Inspecting"
            "prepare" -> "Preparing"
            "create" -> "Creating"
            "update" -> "Updating"
            "publish" -> "Publishing"
            "rotate" -> "Rotating"
            "generate" -> "Generating"
            "explain" -> "Gathering"
            "analyze" -> "Analyzing"
            "search" -> "Searching"
            _ -> nil
          end

        detail = String.trim(rest)

        cond do
          is_nil(job) -> fallback_sentence(trimmed)
          detail == "" -> "#{job}..."
          true -> "#{job} #{truncate_detail(detail)}..."
        end

      _ ->
        fallback_sentence(trimmed)
    end
  end

  defp fallback_sentence(""), do: nil
  defp fallback_sentence(text), do: "#{truncate_detail(text)}..."

  defp truncate_detail(detail) do
    detail
    |> String.trim_leading("whether ")
    |> String.trim_leading("if ")
    |> String.slice(0, 96)
    |> String.trim()
  end

  defp fallback_progress_label("builder_assistant"), do: "Reviewing your agent setup..."
  defp fallback_progress_label("integration_advisor"), do: "Gathering integration details..."
  defp fallback_progress_label("music_specialist"), do: "Checking music results..."
  defp fallback_progress_label("document_specialist"), do: "Reviewing documents and research..."
  defp fallback_progress_label(_id), do: "Working on the request..."
end
