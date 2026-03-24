defmodule Vibe.AI.AgentRuntime do
  @moduledoc false

  require Logger

  @claude_api "https://api.anthropic.com/v1/messages"

  defmodule Config do
    @enforce_keys [:model, :system_prompt, :tools, :execute_tools]
    defstruct model: nil,
              max_tokens: 1600,
              max_depth: 3,
              system_prompt: nil,
              tools: [],
              execute_tools: nil,
              state: %{},
              callback: nil,
              stream_text?: true,
              missing_api_key_error: "ANTHROPIC_API_KEY not configured",
              depth_error: "Max tool depth reached",
              request_label: "AgentRuntime"
  end

  def run(messages, opts) when is_list(messages) do
    config = normalize_config(opts)
    api_key = System.get_env("ANTHROPIC_API_KEY") || System.get_env("CLAUDE_API_KEY")

    if is_nil(api_key) do
      {:error, config.missing_api_key_error}
    else
      do_run(messages, config, api_key, 0, "")
    end
  end

  defp do_run(_messages, %Config{max_depth: max_depth} = config, _api_key, depth, _accumulated_text)
       when depth > max_depth do
    {:error, config.depth_error}
  end

  defp do_run(messages, %Config{} = config, api_key, depth, accumulated_text) do
    case request_completion_stream(messages, config, api_key) do
      {:ok, reply} ->
        {:ok, accumulated_text <> reply, config.state}

      {:tool_use, tool_calls, partial_response, partial_text} ->
        callback = config.callback || fn _event -> :ok end
        {tool_results, next_state} = config.execute_tools.(tool_calls, config.state, callback)

        do_run(
          messages ++ [
            %{role: "assistant", content: partial_response},
            %{role: "user", content: tool_results}
          ],
          %{config | state: next_state},
          api_key,
          depth + 1,
          accumulated_text <> partial_text
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_completion_stream(messages, %Config{} = config, api_key) do
    body =
      Jason.encode!(%{
        model: config.model,
        max_tokens: config.max_tokens,
        system: resolve_system_prompt(config.system_prompt, config.state),
        tools: config.tools,
        messages: messages,
        stream: true
      })

    headers = [
      {"content-type", "application/json"},
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"}
    ]

    request = Finch.build(:post, @claude_api, headers, body)
    callback = config.callback || fn _event -> :ok end

    result =
      Finch.stream(
        request,
        Vibe.Finch,
        %{text: "", tool_calls: [], current_tool_index: -1, stop_reason: nil, buffer: ""},
        fn
          {:status, status}, acc ->
            Map.put(acc, :status, status)

          {:headers, resp_headers}, acc ->
            Map.put(acc, :headers, resp_headers)

          {:data, data}, acc ->
            {events, buffer} = parse_sse_events((acc.buffer || "") <> data)
            acc = Map.put(acc, :buffer, buffer)

            Enum.reduce(events, acc, fn event, inner_acc ->
              case event do
                %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}} ->
                  if config.stream_text? do
                    callback.(%{type: :text, content: text})
                  end

                  Map.update(inner_acc, :text, text, &(&1 <> text))

                %{
                  "type" => "content_block_start",
                  "content_block" => %{"type" => "tool_use"} = tool
                } ->
                  new_tool = Map.put(tool, "input_json", "")
                  new_index = length(inner_acc.tool_calls)

                  inner_acc
                  |> Map.update(:tool_calls, [new_tool], &(&1 ++ [new_tool]))
                  |> Map.put(:current_tool_index, new_index)

                %{
                  "type" => "content_block_delta",
                  "delta" => %{"type" => "input_json_delta", "partial_json" => json}
                } ->
                  idx = inner_acc.current_tool_index

                  if idx >= 0 do
                    updated_tools =
                      List.update_at(inner_acc.tool_calls, idx, fn tool ->
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
        end
      )

    case result do
      {:ok, final_acc} ->
        case final_acc.status do
          status when is_integer(status) and status != 200 ->
            Logger.error("[#{config.request_label}] Claude streaming request failed with status #{status}")
            {:error, "API error: #{status}"}

          _ ->
            case final_acc.stop_reason do
              "tool_use" ->
                tools_with_input =
                  Enum.map(final_acc.tool_calls, fn tool ->
                    input =
                      case Jason.decode(tool["input_json"] || "{}") do
                        {:ok, parsed} -> parsed
                        _ -> %{}
                      end

                    Map.put(tool, "input", input)
                  end)

                {:tool_use, tools_with_input, build_content_blocks(final_acc), final_acc.text}

              _ ->
                {:ok, final_acc.text}
            end
        end

      {:error, reason} ->
        Logger.error("[#{config.request_label}] Claude streaming request failed: #{inspect(reason)}")
        {:error, "AI request failed."}
    end
  end

  defp normalize_config(%Config{} = config), do: config

  defp normalize_config(opts) when is_list(opts) do
    opts
    |> Enum.into(%{})
    |> normalize_config()
  end

  defp normalize_config(opts) when is_map(opts) do
    struct!(Config, opts)
  end

  defp resolve_system_prompt(system_prompt, state) when is_function(system_prompt, 1),
    do: system_prompt.(state)

  defp resolve_system_prompt(system_prompt, _state) when is_binary(system_prompt),
    do: system_prompt

  defp parse_sse_events(data) do
    data =
      data
      |> to_string()
      |> String.replace("\r\n", "\n")

    chunks = String.split(data, "\n\n", trim: false)

    {complete_chunks, remaining} =
      if String.ends_with?(data, "\n\n") do
        {Enum.reject(chunks, &(&1 == "")), ""}
      else
        case Enum.split(chunks, max(length(chunks) - 1, 0)) do
          {complete, [tail]} -> {Enum.reject(complete, &(&1 == "")), tail}
          {complete, []} -> {Enum.reject(complete, &(&1 == "")), ""}
        end
      end

    events =
      complete_chunks
      |> Enum.map(&parse_sse_event_block/1)
      |> Enum.reject(&is_nil/1)

    {events, remaining}
  end

  defp parse_sse_event_block(chunk) do
    payload =
      chunk
      |> String.split("\n", trim: false)
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(fn line ->
        line
        |> String.replace_prefix("data:", "")
        |> String.trim_leading()
      end)
      |> Enum.join("\n")

    cond do
      payload == "" -> nil
      payload == "[DONE]" -> nil
      true ->
        case Jason.decode(payload) do
          {:ok, parsed} -> parsed
          _ -> nil
        end
    end
  end

  defp build_content_blocks(acc) do
    blocks =
      if acc.text != "" do
        [%{"type" => "text", "text" => acc.text}]
      else
        []
      end

    acc.tool_calls
    |> Enum.reduce(blocks, fn tool, acc_blocks ->
      input =
        case Jason.decode(tool["input_json"] || "{}") do
          {:ok, parsed} -> parsed
          _ -> %{}
        end

      acc_blocks ++
        [
          %{
            "type" => "tool_use",
            "id" => tool["id"],
            "name" => tool["name"],
            "input" => input
          }
        ]
    end)
  end
end
