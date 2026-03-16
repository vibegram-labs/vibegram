defmodule Vibe.AI.StandaloneAgent do
  @moduledoc false

  require Logger

  alias Vibe.Chat
  alias Vibe.Notifications
  alias Vibe.Agent, as: AgentSchema
  alias Vibe.AI.Agent, as: ChatAgent
  alias Vibe.AI.TTS
  alias Vibe.Chat.AgentMessageCrypto

  def invoke(%AgentSchema{} = agent, params) when is_map(params) do
    response_mode = normalize_response_mode(params["responseMode"] || params["response_mode"])
    message = normalize_string(params["message"])
    vibe_chat_id = normalize_string(params["vibeChatId"] || params["vibe_chat_id"])
    attachments = normalize_attachments(params["attachments"])
    requested_output_mode = normalize_string(params["outputMode"] || params["output_mode"])
    reply_to_id = normalize_string(params["replyToId"] || params["reply_to_id"])

    cond do
      agent.status != "published" ->
        {:error, :agent_unavailable}

      message == nil ->
        {:error, :missing_message}

      response_mode == "send" and is_nil(vibe_chat_id) ->
        {:error, :missing_chat_id}

      response_mode == "send" and not Chat.is_participant?(vibe_chat_id, agent.agent_user_id) ->
        {:error, :chat_not_attached}

      true ->
        with {:ok, outputs} <- generate_outputs(agent, message, attachments, requested_output_mode, vibe_chat_id),
             {:ok, deliveries} <- maybe_deliver(agent, vibe_chat_id, outputs, response_mode, reply_to_id) do
          {:ok, %{outputs: outputs, vibe_deliveries: deliveries}}
        end
    end
  end

  def handle_chat_message(%AgentSchema{} = agent, chat_id, message, opts \\ []) do
    params = %{
      "message" => message,
      "responseMode" => "send",
      "vibeChatId" => chat_id,
      "outputMode" => Keyword.get(opts, :output_mode),
      "replyToId" => Keyword.get(opts, :reply_to_id),
      "attachments" => Keyword.get(opts, :attachments, [])
    }

    invoke(agent, params)
  end

  defp generate_outputs(agent, message, attachments, requested_output_mode, vibe_chat_id) do
    image_urls =
      attachments
      |> Enum.filter(&(&1.type == "image"))
      |> Enum.map(& &1.url)

    system_prompt = build_system_prompt(agent)

    {:ok, collected} = Elixir.Agent.start_link(fn -> %{text: "", outputs: []} end)

    callback = fn
      %{type: :text, content: chunk} ->
        Elixir.Agent.update(collected, fn acc -> %{acc | text: acc.text <> chunk} end)

      %{type: :tool_result, tool: tool_name, result: result} ->
        case tool_output_from_result(tool_name, result) do
          nil ->
            :ok

          output ->
            Elixir.Agent.update(collected, fn acc ->
              %{acc | outputs: merge_outputs(acc.outputs, [output])}
            end)
        end

      _ ->
        :ok
    end

    try do
      with {:ok, final_text} <-
             ChatAgent.stream_response(
               message,
               callback,
               images: image_urls,
               chat_id: vibe_chat_id,
               user_id: agent.owner_user_id,
               system_prompt: system_prompt,
               enabled_tools: agent.enabled_tools || []
             ) do
        accumulated = Elixir.Agent.get(collected, & &1)
        outputs = finalize_outputs(agent, final_text, accumulated.outputs, requested_output_mode)
        {:ok, outputs}
      end
    after
      Elixir.Agent.stop(collected)
    end
  end

  defp maybe_deliver(_agent, _chat_id, outputs, "reply", _reply_to_id), do: {:ok, []}

  defp maybe_deliver(agent, chat_id, outputs, "send", reply_to_id) do
    deliveries =
      Enum.map(outputs, fn output ->
        deliver_output_to_chat(agent, chat_id, output, reply_to_id)
      end)

    if Enum.all?(deliveries, &match?({:ok, _}, &1)) do
      {:ok, Enum.map(deliveries, fn {:ok, payload} -> payload end)}
    else
      {:error, :delivery_failed}
    end
  end

  defp deliver_output_to_chat(agent, chat_id, output, reply_to_id) do
    message_id = Ecto.UUID.generate()
    timestamp = :os.system_time(:millisecond)
    message_type = output.type || "text"
    plain_text = normalize_string(output.text) || ""
    metadata =
      output.metadata || %{}
      |> Map.put("replyToId", reply_to_id)
      |> Map.put("isAgentMessage", true)
      |> Map.put("agentId", agent.id)
      |> Map.put("agentName", agent.display_name)

    payload =
      %{
        "id" => message_id,
        "fromId" => agent.agent_user_id,
        "chatId" => chat_id,
        "encryptedContent" => "",
        "plainContent" => plain_text,
        "plaintext" => plain_text,
        "type" => message_type,
        "timestamp" => timestamp,
        "status" => "sent",
        "isAgentMessage" => true,
        "agentName" => agent.display_name,
        "agentId" => agent.id,
        "mediaUrl" => output.mediaUrl,
        "metadata" => metadata,
        "replyToId" => reply_to_id
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    message_attrs =
      %{
        id: message_id,
        chat_id: chat_id,
        from_id: agent.agent_user_id,
        encrypted_content: AgentMessageCrypto.encrypt_for_storage(plain_text),
        type: message_type,
        media_url: output.mediaUrl,
        metadata: metadata,
        reply_to_id: reply_to_id,
        timestamp: timestamp
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Chat.add_message(message_attrs, acting_user_id: agent.agent_user_id) do
      {:ok, _message} ->
        VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "message", payload)

        Chat.get_all_participant_settings(chat_id)
        |> Enum.each(fn participant ->
          if participant.user_id != agent.agent_user_id and not participant.muted do
            _ =
              Notifications.send_message_push(participant.user_id, %{
                "chat_id" => chat_id,
                "message_id" => message_id,
                "from_id" => agent.agent_user_id,
                "type" => message_type,
                "body" => plain_text,
                "media_url" => output.mediaUrl
              })
          end
        end)

        {:ok, %{messageId: message_id, type: message_type, mediaUrl: output.mediaUrl}}

      error ->
        error
    end
  end

  defp build_system_prompt(agent) do
    [
      "You are #{agent.display_name}, a custom AI agent inside the Vibe app.",
      "Respond clearly and practically.",
      if(agent.persona, do: "Persona: #{agent.persona}", else: nil),
      if(agent.welcome_message, do: "Welcome message: #{agent.welcome_message}", else: nil),
      agent.system_prompt
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp normalize_attachments(value) when is_list(value) do
    Enum.map(value, fn item ->
      %{
        type: normalize_string(item["type"] || item[:type]) || "file",
        url: normalize_string(item["url"] || item[:url] || item["mediaUrl"] || item[:mediaUrl])
      }
    end)
    |> Enum.filter(&is_binary(&1.url))
  end

  defp normalize_attachments(_), do: []

  defp normalize_response_mode(value) do
    case normalize_string(value) do
      "send" -> "send"
      _ -> "reply"
    end
  end

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_), do: nil

  defp finalize_outputs(agent, final_text, tool_outputs, requested_output_mode) do
    base_outputs =
      tool_outputs
      |> List.wrap()
      |> Enum.reject(&is_nil/1)

    normalized_text =
      final_text
      |> to_string()
      |> String.trim()

    case requested_output_mode do
      "voice" ->
        if normalized_text != "" and "voice" in (agent.output_modes || []) do
          case TTS.synthesize(normalized_text, voice: agent.voice_profile || "alloy") do
            {:ok, voice} ->
              base_outputs ++
                [
                  %{
                    type: "voice",
                    text: normalized_text,
                    mediaUrl: voice.media_url,
                    metadata: %{"duration" => voice.duration, "mimeType" => "audio/mpeg"}
                  }
                ]

            {:error, reason} ->
              Logger.warning("[StandaloneAgent] TTS failed, falling back to text: #{inspect(reason)}")
              maybe_append_text_output(base_outputs, normalized_text)
          end
        else
          maybe_append_text_output(base_outputs, normalized_text)
        end

      _ ->
        maybe_append_text_output(base_outputs, normalized_text)
    end
  end

  defp maybe_append_text_output(outputs, ""), do: outputs
  defp maybe_append_text_output(outputs, nil), do: outputs

  defp maybe_append_text_output(outputs, text) do
    outputs ++ [%{type: "text", text: text, metadata: %{}}]
  end

  defp tool_output_from_result(tool_name, result)
       when tool_name in ["create_document", "edit_rows", "delete_rows", "export_rows"] and is_map(result) do
    ok? = Map.get(result, :ok) || Map.get(result, "ok")

    file_url =
      Map.get(result, :file_url) ||
        Map.get(result, "file_url") ||
        Map.get(result, :download_path) ||
        Map.get(result, "download_path")

    with true <- ok? == true,
         url when is_binary(url) <- normalize_string(file_url) do
      mime_type = detect_mime_type(url)
      metadata = %{"fileName" => file_name_from_url(url), "mimeType" => mime_type}

      %{
        type: if(image_output?(url, mime_type), do: "image", else: "file"),
        mediaUrl: url,
        metadata: metadata
      }
    else
      _ -> nil
    end
  end

  defp tool_output_from_result(_tool_name, _result), do: nil

  defp merge_outputs(existing, new_outputs) do
    (List.wrap(existing) ++ List.wrap(new_outputs))
    |> Enum.uniq_by(fn output -> {output.type, output.mediaUrl, output.text} end)
  end

  defp image_output?(url, mime_type) do
    mime_type in ["image/png", "image/jpeg", "image/webp", "image/gif"] or
      String.match?(String.downcase(url), ~r/\.(png|jpg|jpeg|webp|gif)(\?|$)/)
  end

  defp detect_mime_type(url) do
    lowered = String.downcase(url)

    cond do
      String.match?(lowered, ~r/\.png(\?|$)/) -> "image/png"
      String.match?(lowered, ~r/\.jpe?g(\?|$)/) -> "image/jpeg"
      String.match?(lowered, ~r/\.webp(\?|$)/) -> "image/webp"
      String.match?(lowered, ~r/\.gif(\?|$)/) -> "image/gif"
      String.match?(lowered, ~r/\.pdf(\?|$)/) -> "application/pdf"
      String.match?(lowered, ~r/\.xlsx?(\?|$)/) -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      String.match?(lowered, ~r/\.csv(\?|$)/) -> "text/csv"
      true -> "application/octet-stream"
    end
  end

  defp file_name_from_url(url) do
    url
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      nil -> "document"
      path ->
        case Path.basename(path) do
          "" -> "document"
          name -> name
        end
    end
  rescue
    _ -> "document"
  end
end
