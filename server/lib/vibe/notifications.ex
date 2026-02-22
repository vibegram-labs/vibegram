defmodule Vibe.Notifications do
  @moduledoc false

  require Logger

  alias Vibe.Accounts

  @expo_push_url "https://exp.host/--/api/v2/push/send"
  @expo_receipts_url "https://exp.host/--/api/v2/push/getReceipts"
  @default_message_title "New message"

  def send_incoming_call_push(to_user_id, payload) when is_binary(to_user_id) and is_map(payload) do
    with to_user when not is_nil(to_user) <- Accounts.get_user(to_user_id),
         push_token when is_binary(push_token) <- normalized_push_token(to_user.push_token),
         true <- push_token != "" do
      call_type = normalize_call_type(payload["callType"] || payload["call_type"])
      from_user_id = payload["fromUserId"] || payload["from_user_id"]
      caller_name = payload["fromUserName"] || payload["from_user_name"] || from_user_id || "Unknown"
      caller_image =
        normalize_push_image(
          payload["fromUserImage"] || payload["from_user_image"],
          from_user_id
        )

      base_data = %{
        type: "call-start",
        callId: payload["callId"] || payload["call_id"],
        callType: call_type,
        fromUserId: from_user_id,
        fromUserName: caller_name
      }

      data =
        case caller_image do
          value when is_binary(value) and value != "" -> Map.put(base_data, :fromUserImage, value)
          _ -> base_data
        end

      base_message = %{
        to: push_token,
        sound: "default",
        priority: "high",
        title: caller_name,
        body: "Incoming #{call_type} call",
        data: data
      }

      message =
        case caller_image do
          value when is_binary(value) and value != "" ->
            base_message
            |> Map.put(:mutableContent, true)
            |> Map.put(:richContent, %{image: value})

          _ ->
            base_message
        end

      request =
        Finch.build(
          :post,
          @expo_push_url,
          [{"content-type", "application/json"}],
          Jason.encode!(message)
        )

      case Finch.request(request, Vibe.Finch, receive_timeout: 7_000) do
        {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
          log_expo_push_result("call", to_user_id, body)
          :ok

        {:ok, %Finch.Response{status: status, body: body}} ->
          Logger.warning(
            "[Notifications] Expo push failed status=#{status} to_user=#{to_user_id} body=#{String.slice(body || "", 0, 240)}"
          )

          :error

        {:error, reason} ->
          Logger.warning("[Notifications] Expo push request failed to_user=#{to_user_id} reason=#{inspect(reason)}")
          :error
      end
    else
      _ ->
        Logger.info("[Notifications] Incoming call push skipped: missing target user/push token to_user=#{to_user_id}")
        :noop
    end
  end

  def send_incoming_call_push(_to_user_id, _payload), do: :noop

  def send_message_push(to_user_id, payload) when is_binary(to_user_id) and is_map(payload) do
    with to_user when not is_nil(to_user) <- Accounts.get_user(to_user_id),
         push_token when is_binary(push_token) <- normalized_push_token(to_user.push_token),
         true <- push_token != "" do
      from_user_id = payload["fromUserId"] || payload["from_user_id"] || payload["from_id"]
      sender = if is_binary(from_user_id), do: Accounts.get_user(from_user_id), else: nil
      sender_name_raw = (sender && (sender.name || sender.username)) || @default_message_title
      sender_name = truncate_text(sender_name_raw, 64)
      message_type = payload["type"] || "text"
      message_type_normalized = message_type |> to_string() |> String.downcase()
      message_body = resolve_message_body(payload, message_type)
      sender_image = normalize_push_image(sender && sender.profile_image, from_user_id)
      media_preview_image =
        if message_type_normalized in ["image", "video", "gif"] do
          resolve_push_media_image(payload)
        else
          nil
        end
      mutable_content_enabled =
        (is_binary(sender_image) and sender_image != "")
        or (is_binary(media_preview_image) and media_preview_image != "")

      base_data = %{
        type: "new_message",
        chatId: payload["chatId"] || payload["chat_id"],
        messageId: payload["messageId"] || payload["message_id"],
        fromUserId: from_user_id,
        fromUserName: sender_name,
        messageType: message_type
      }

      data =
        case sender_image do
          value when is_binary(value) and value != "" -> Map.put(base_data, :fromUserImage, value)
          _ -> base_data
        end

      base_message = %{
        to: push_token,
        sound: "default",
        priority: "high",
        title: sender_name,
        body: message_body,
        data: data
      }

      message =
        base_message
        |> Map.put(:mutableContent, true)
        |> then(fn payload_map ->
          case media_preview_image do
            value when is_binary(value) and value != "" ->
              Map.put(payload_map, :richContent, %{image: value})

            _ ->
              payload_map
          end
        end)

      request =
        Finch.build(
          :post,
          @expo_push_url,
          [{"content-type", "application/json"}],
          Jason.encode!(message)
        )

      Logger.info(
        "[Notifications] Sending message push to_user=#{to_user_id} chat_id=#{data.chatId} message_id=#{data.messageId} from_user=#{from_user_id} mutable_content=#{mutable_content_enabled} avatar_present=#{is_binary(sender_image) and sender_image != ""} media_preview_present=#{is_binary(media_preview_image) and media_preview_image != ""} message_type=#{message_type_normalized}"
      )

      case Finch.request(request, Vibe.Finch, receive_timeout: 7_000) do
        {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
          log_expo_push_result("message", to_user_id, body)
          :ok

        {:ok, %Finch.Response{status: status, body: body}} ->
          Logger.warning(
            "[Notifications] Message push failed status=#{status} to_user=#{to_user_id} body=#{String.slice(body || "", 0, 240)}"
          )

          :error

        {:error, reason} ->
          Logger.warning("[Notifications] Message push request failed to_user=#{to_user_id} reason=#{inspect(reason)}")
          :error
      end
    else
      _ ->
        Logger.info("[Notifications] Message push skipped: missing target user/push token to_user=#{to_user_id}")
        :noop
    end
  end

  def send_message_push(_to_user_id, _payload), do: :noop

  defp normalized_push_token(token) when is_binary(token), do: String.trim(token)
  defp normalized_push_token(_), do: nil

  defp normalize_call_type(value) when is_binary(value) do
    if String.downcase(value) == "video", do: "video", else: "voice"
  end

  defp normalize_call_type(_), do: "voice"

  defp resolve_message_body(payload, message_type) do
    body =
      case payload["body"] || payload["text"] do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    if body != "" do
      truncate_text(body, 160)
    else
      case to_string(message_type || "text") do
        "image" -> "Photo"
        "video" -> "Video"
        "voice" -> "Voice message"
        "music" -> "Audio"
        "file" -> "File"
        "location" -> "Location"
        "contact" -> "Contact"
        "gif" -> "GIF"
        _ -> "You have a new message"
      end
    end
  end

  defp resolve_push_media_image(payload) when is_map(payload) do
    candidate =
      payload["media_image"] ||
      payload["mediaImage"] ||
      payload["media_url"] ||
      payload["mediaUrl"] ||
      map_value(payload["richContent"], "image") ||
      map_value(payload["_richContent"], "image")

    case candidate do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        cond do
          trimmed == "" ->
            nil

          String.starts_with?(String.downcase(trimmed), ["http://", "https://"]) ->
            if String.length(trimmed) <= 2048 do
              trimmed
            else
              Logger.warning(
                "[Notifications] media preview image URL too long length=#{String.length(trimmed)}"
              )

              nil
            end

          true ->
            nil
        end

      _ ->
        nil
    end
  end

  defp resolve_push_media_image(_), do: nil

  defp map_value(value, key) when is_map(value), do: value[key]
  defp map_value(_value, _key), do: nil

  defp truncate_text(text, max_len) when is_binary(text) and is_integer(max_len) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 1) <> "…"
    else
      text
    end
  end

  # APNs payload must stay compact.
  # For inline/base64 avatars we switch to a compact API URL and let the iOS
  # notification service extension fetch/attach the image.
  defp normalize_push_image(value, from_user_id) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        Logger.info("[Notifications] push image skipped empty from_user=#{from_user_id}")
        nil

      String.starts_with?(String.downcase(trimmed), ["http://", "https://"]) ->
        if String.length(trimmed) <= 1024 do
          Logger.info("[Notifications] push image using remote URL from_user=#{from_user_id}")
          trimmed
        else
          Logger.warning("[Notifications] push image URL too long from_user=#{from_user_id} length=#{String.length(trimmed)}")
          nil
        end

      true ->
        Logger.info("[Notifications] push image using proxy URL from_user=#{from_user_id}")
        avatar_proxy_url(from_user_id)
    end
  end

  defp normalize_push_image(_value, from_user_id) do
    Logger.info("[Notifications] push image non-binary value, using proxy URL from_user=#{from_user_id}")
    avatar_proxy_url(from_user_id)
  end

  defp avatar_proxy_url(user_id) when is_binary(user_id) and user_id != "" do
    with base_url when is_binary(base_url) <- sanitized_endpoint_url(),
         true <- base_url != "" do
      encoded_user_id = URI.encode_www_form(user_id)
      "#{base_url}/api/push/avatar/#{encoded_user_id}"
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp avatar_proxy_url(_), do: nil

  defp sanitized_endpoint_url do
    VibeWeb.Endpoint.url()
    |> to_string()
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.replace(~r/\[(https?:\/\/)/i, "\\1")
    |> String.replace(~r/\](?=\/|$)/, "")
    |> String.replace(~r/^(https?:\/\/)+/i, fn prefix ->
      case Regex.run(~r/https?:\/\//i, prefix) do
        [single | _] -> String.downcase(single)
        _ -> "https://"
      end
    end)
    |> String.trim_trailing("/")
  end

  defp log_expo_push_result(kind, to_user_id, body) do
    with {:ok, decoded} <- Jason.decode(body || ""),
         data <- Map.get(decoded, "data"),
         ticket when is_map(ticket) <- normalize_expo_ticket(data) do
      case ticket["status"] do
        "ok" ->
          ticket_id = ticket["id"]

          Logger.info(
            "[Notifications] #{kind} push accepted by Expo to_user=#{to_user_id} ticket_id=#{ticket_id}"
          )

          if is_binary(ticket_id) and ticket_id != "" do
            schedule_expo_receipt_check(kind, to_user_id, ticket_id)
          end

        "error" ->
          Logger.warning(
            "[Notifications] #{kind} push rejected by Expo to_user=#{to_user_id} details=#{inspect(ticket["details"])} message=#{inspect(ticket["message"])}"
          )

        other ->
          Logger.warning(
            "[Notifications] #{kind} push unexpected Expo ticket to_user=#{to_user_id} status=#{inspect(other)} ticket=#{inspect(ticket)}"
          )
      end
    else
      _ ->
        Logger.warning(
          "[Notifications] #{kind} push response parse failed to_user=#{to_user_id} body=#{String.slice(body || "", 0, 240)}"
        )
    end
  end

  defp normalize_expo_ticket(data) when is_map(data), do: data

  defp normalize_expo_ticket(data) when is_list(data) do
    case data do
      [ticket | _] when is_map(ticket) -> ticket
      _ -> nil
    end
  end

  defp normalize_expo_ticket(_), do: nil

  defp schedule_expo_receipt_check(kind, to_user_id, ticket_id) do
    Task.start(fn ->
      Process.sleep(1_500)
      fetch_and_log_expo_receipt(kind, to_user_id, ticket_id)
    end)
  end

  defp fetch_and_log_expo_receipt(kind, to_user_id, ticket_id) do
    payload = %{ids: [ticket_id]}

    request =
      Finch.build(
        :post,
        @expo_receipts_url,
        [{"content-type", "application/json"}],
        Jason.encode!(payload)
      )

    case Finch.request(request, Vibe.Finch, receive_timeout: 7_000) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        with {:ok, decoded} <- Jason.decode(body || ""),
             data when is_map(data) <- Map.get(decoded, "data"),
             receipt when is_map(receipt) <- Map.get(data, ticket_id) do
          case receipt["status"] do
            "ok" ->
              Logger.info(
                "[Notifications] #{kind} push receipt ok to_user=#{to_user_id} ticket_id=#{ticket_id}"
              )

            "error" ->
              Logger.warning(
                "[Notifications] #{kind} push receipt error to_user=#{to_user_id} ticket_id=#{ticket_id} details=#{inspect(receipt["details"])} message=#{inspect(receipt["message"])}"
              )

            other ->
              Logger.warning(
                "[Notifications] #{kind} push receipt unexpected status to_user=#{to_user_id} ticket_id=#{ticket_id} status=#{inspect(other)} receipt=#{inspect(receipt)}"
              )
          end
        else
          _ ->
            Logger.warning(
              "[Notifications] #{kind} push receipt parse failed to_user=#{to_user_id} ticket_id=#{ticket_id} body=#{String.slice(body || "", 0, 240)}"
            )
        end

      {:ok, %Finch.Response{status: status, body: body}} ->
        Logger.warning(
          "[Notifications] #{kind} push receipt request failed status=#{status} to_user=#{to_user_id} ticket_id=#{ticket_id} body=#{String.slice(body || "", 0, 240)}"
        )

      {:error, reason} ->
        Logger.warning(
          "[Notifications] #{kind} push receipt request error to_user=#{to_user_id} ticket_id=#{ticket_id} reason=#{inspect(reason)}"
        )
    end
  end
end
