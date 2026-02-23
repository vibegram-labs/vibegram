defmodule Vibe.Notifications do
  @moduledoc false

  require Logger

  alias Vibe.Accounts

  @expo_push_url "https://exp.host/--/api/v2/push/send"
  @expo_receipts_url "https://exp.host/--/api/v2/push/getReceipts"
  @default_message_title "New message"
  @apns_voip_prod_base "https://api.push.apple.com"
  @apns_voip_sandbox_base "https://api.sandbox.push.apple.com"
  @apns_voip_jwt_cache_ttl_secs 50 * 60

  def send_incoming_call_push(to_user_id, payload) when is_binary(to_user_id) and is_map(payload) do
    with to_user when not is_nil(to_user) <- Accounts.get_user(to_user_id),
         push_targets when is_map(push_targets) <- normalized_push_targets(to_user.push_token) do
      call_type = normalize_call_type(payload["callType"] || payload["call_type"])
      call_id = payload["callId"] || payload["call_id"]
      from_user_id = payload["fromUserId"] || payload["from_user_id"]
      caller_name = payload["fromUserName"] || payload["from_user_name"] || from_user_id || "Unknown"
      caller_image =
        normalize_push_image(
          payload["fromUserImage"] || payload["from_user_image"],
          from_user_id
        )

      Logger.info(
        "[Notifications] Incoming call push routing to_user=#{to_user_id} call_id=#{inspect(call_id)} call_type=#{call_type} targets=#{inspect(describe_push_targets(push_targets))}"
      )

      base_data = %{
        event: "call-start",
        type: "call-start",
        callId: call_id,
        callType: call_type,
        fromUserId: from_user_id,
        fromUserName: caller_name,
        nativeCall: true
      }

      data =
        case caller_image do
          value when is_binary(value) and value != "" -> Map.put(base_data, :fromUserImage, value)
          _ -> base_data
        end

      has_voip_target = is_binary(push_targets[:apns_voip]) and push_targets[:apns_voip] != ""

      voip_result =
        send_apns_voip_incoming_call_push(
          push_targets[:apns_voip],
          to_user_id,
          caller_name,
          call_type,
          data
        )

      expo_result =
        cond do
          has_voip_target and voip_result == {:ok, :apns_voip} ->
            Logger.info(
              "[Notifications] Expo call push skipped to_user=#{to_user_id} reason=voip_accepted"
            )

            :noop

          true ->
            send_expo_incoming_call_push(
              push_targets[:expo],
              to_user_id,
              caller_name,
              call_type,
              caller_image,
              data
            )
        end

      case {expo_result, voip_result} do
        {{:ok, :expo}, _} -> :ok
        {_, {:ok, :apns_voip}} -> :ok
        {:noop, :noop} ->
          Logger.info("[Notifications] Incoming call push skipped: no usable Expo/VoIP token to_user=#{to_user_id}")
          :noop

        {left, right} ->
          Logger.warning("[Notifications] Incoming call push delivery failed to_user=#{to_user_id} expo=#{inspect(left)} voip=#{inspect(right)}")
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
         push_targets when is_map(push_targets) <- normalized_push_targets(to_user.push_token),
         push_token when is_binary(push_token) <- push_targets.expo,
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

      data_with_avatar =
        case sender_image do
          value when is_binary(value) and value != "" -> Map.put(base_data, :fromUserImage, value)
          _ -> base_data
        end

      data =
        case media_preview_image do
          value when is_binary(value) and value != "" ->
            data_with_avatar
            |> Map.put(:mediaImage, value)
            |> Map.put(:mediaUrl, value)

          _ ->
            data_with_avatar
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
              payload_map
              |> Map.put(:richContent, %{image: value})
              |> Map.put(:image, value)

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

  defp send_expo_incoming_call_push(push_token, _to_user_id, _caller_name, _call_type, _caller_image, _data)
       when not is_binary(push_token) do
    :noop
  end

  defp send_expo_incoming_call_push(push_token, _to_user_id, _caller_name, _call_type, _caller_image, _data)
       when is_binary(push_token) and push_token == "" do
    :noop
  end

  defp send_expo_incoming_call_push(push_token, to_user_id, caller_name, call_type, _caller_image, data) do
    message = %{
      to: push_token,
      sound: "default",
      priority: "high",
      title: caller_name,
      body: "Incoming #{call_type} call",
      data: data
    }

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
        {:ok, :expo}

      {:ok, %Finch.Response{status: status, body: body}} ->
        Logger.warning(
          "[Notifications] Expo push failed status=#{status} to_user=#{to_user_id} body=#{String.slice(body || "", 0, 240)}"
        )

        :error

      {:error, reason} ->
        Logger.warning("[Notifications] Expo push request failed to_user=#{to_user_id} reason=#{inspect(reason)}")
        :error
    end
  end

  defp send_apns_voip_incoming_call_push(voip_token, _to_user_id, _caller_name, _call_type, _data)
       when not is_binary(voip_token) do
    :noop
  end

  defp send_apns_voip_incoming_call_push(voip_token, _to_user_id, _caller_name, _call_type, _data)
       when is_binary(voip_token) and voip_token == "" do
    :noop
  end

  defp send_apns_voip_incoming_call_push(voip_token, to_user_id, caller_name, call_type, data) do
    call_id = Map.get(data, :callId, nil) |> to_string()
    token_hint = token_hint(voip_token)

    Logger.info(
      "[Notifications] APNs VoIP attempt to_user=#{to_user_id} call_id=#{inspect(call_id)} call_type=#{call_type} token=#{token_hint}"
    )

    with {:ok, config} <- apns_voip_config(),
         {:ok, jwt} <- apns_voip_jwt(config),
         {:ok, body} <- apns_voip_payload(data, caller_name, call_type) do
      url = "#{config.base_url}/3/device/#{URI.encode(voip_token)}"

      headers = [
        {"content-type", "application/json"},
        {"authorization", "bearer " <> jwt},
        {"apns-push-type", "voip"},
        {"apns-priority", "10"},
        {"apns-topic", config.topic},
        {"apns-expiration", "0"},
        {"apns-collapse-id", Map.get(data, :callId, "") |> to_string()}
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

      request = Finch.build(:post, url, headers, body)

      case Finch.request(request, Vibe.APNsFinch, receive_timeout: 7_000) do
        {:ok, %Finch.Response{status: 200}} ->
          Logger.info(
            "[Notifications] APNs VoIP push accepted to_user=#{to_user_id} call_type=#{call_type} topic=#{config.topic} base_url=#{config.base_url}"
          )
          {:ok, :apns_voip}

        {:ok, %Finch.Response{status: status, body: response_body}} ->
          Logger.warning(
            "[Notifications] APNs VoIP push failed status=#{status} to_user=#{to_user_id} topic=#{config.topic} base_url=#{config.base_url} body=#{String.slice(response_body || "", 0, 240)}"
          )
          :error

        {:error, reason} ->
          Logger.warning(
            "[Notifications] APNs VoIP request failed to_user=#{to_user_id} topic=#{config.topic} base_url=#{config.base_url} reason=#{inspect(reason)}"
          )
          :error
      end
    else
      {:error, :missing_config} ->
        Logger.info(
          "[Notifications] APNs VoIP push skipped: missing APNs VoIP config #{inspect(apns_voip_config_presence())}"
        )
        :noop

      {:error, reason} ->
        Logger.warning("[Notifications] APNs VoIP push setup failed to_user=#{to_user_id} reason=#{inspect(reason)}")
        :error
    end
  end

  defp normalized_push_targets(token) when is_binary(token) do
    trimmed = String.trim(token)

    cond do
      trimmed == "" ->
        nil

      String.starts_with?(trimmed, "ExponentPushToken[") ->
        %{expo: trimmed, fcm: nil, apns: nil, apns_voip: nil}

      true ->
        case Jason.decode(trimmed) do
          {:ok, value} when is_map(value) ->
            %{
              expo: normalize_token_value(value["expo"] || value["expoPushToken"]),
              fcm: normalize_token_value(value["fcm"] || value["fcmPushToken"]),
              apns: normalize_token_value(value["apns"] || value["apnsToken"]),
              apns_voip: normalize_token_value(value["apns_voip"] || value["voip"] || value["voipPushToken"])
            }

          _ ->
            %{expo: trimmed, fcm: nil, apns: nil, apns_voip: nil}
        end
    end
  end

  defp normalized_push_targets(_), do: nil

  defp normalize_token_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_token_value(_), do: nil

  defp describe_push_targets(push_targets) when is_map(push_targets) do
    %{
      expo: token_hint(push_targets[:expo]),
      fcm: token_hint(push_targets[:fcm]),
      apns: token_hint(push_targets[:apns]),
      apns_voip: token_hint(push_targets[:apns_voip])
    }
  end

  defp token_hint(token) when is_binary(token) do
    trimmed = String.trim(token)

    cond do
      trimmed == "" ->
        "empty"

      String.length(trimmed) <= 12 ->
        "len=#{String.length(trimmed)}"

      true ->
        prefix = String.slice(trimmed, 0, 6)
        suffix = String.slice(trimmed, -4, 4)
        "len=#{String.length(trimmed)} #{prefix}...#{suffix}"
    end
  end

  defp token_hint(_), do: "missing"

  defp apns_voip_config_presence do
    env_value = String.downcase(System.get_env("APPLE_VOIP_APNS_ENV") || "")

    %{
      team_id: is_binary(normalize_token_value(System.get_env("APPLE_VOIP_TEAM_ID"))),
      key_id: is_binary(normalize_token_value(System.get_env("APPLE_VOIP_KEY_ID"))),
      private_key: is_binary(normalize_apns_private_key(System.get_env("APPLE_VOIP_PRIVATE_KEY"))),
      topic:
        is_binary(
          (System.get_env("APPLE_VOIP_TOPIC") |> normalize_token_value()) ||
            case System.get_env("APPLE_BUNDLE_ID") |> normalize_token_value() do
              nil -> nil
              bundle_id -> bundle_id <> ".voip"
            end
        ),
      env: if(env_value in ["sandbox", "development", "dev"], do: "sandbox", else: "production")
    }
  end

  defp apns_voip_config do
    team_id = System.get_env("APPLE_VOIP_TEAM_ID") |> normalize_token_value()
    key_id = System.get_env("APPLE_VOIP_KEY_ID") |> normalize_token_value()
    private_key =
      System.get_env("APPLE_VOIP_PRIVATE_KEY")
      |> normalize_apns_private_key()

    topic =
      (System.get_env("APPLE_VOIP_TOPIC") |> normalize_token_value()) ||
        case System.get_env("APPLE_BUNDLE_ID") |> normalize_token_value() do
          nil -> nil
          bundle_id -> bundle_id <> ".voip"
        end

    base_url =
      case String.downcase(System.get_env("APPLE_VOIP_APNS_ENV") || "") do
        "sandbox" -> @apns_voip_sandbox_base
        "development" -> @apns_voip_sandbox_base
        "dev" -> @apns_voip_sandbox_base
        _ -> @apns_voip_prod_base
      end

    if is_binary(team_id) and is_binary(key_id) and is_binary(private_key) and is_binary(topic) do
      {:ok, %{team_id: team_id, key_id: key_id, private_key: private_key, topic: topic, base_url: base_url}}
    else
      {:error, :missing_config}
    end
  end

  defp normalize_apns_private_key(value) when is_binary(value) do
    trimmed = String.trim(value)

    normalized =
      trimmed
      |> String.replace("\\r\\n", "\n")
      |> String.replace("\\n", "\n")
      |> String.replace("\\r", "\n")

    if normalized == "", do: nil, else: normalized
  end

  defp normalize_apns_private_key(_), do: nil

  defp apns_voip_jwt(config) do
    now = System.system_time(:second)
    cache_key = apns_voip_jwt_cache_key(config)

    case :persistent_term.get(cache_key, nil) do
      %{jwt: jwt, iat: iat} when is_binary(jwt) and is_integer(iat) and now - iat < @apns_voip_jwt_cache_ttl_secs ->
        {:ok, jwt}

      _ ->
        header = %{"alg" => "ES256", "kid" => config.key_id}
        claims = %{"iss" => config.team_id, "iat" => now}

        signing_input =
          base64url_encode(Jason.encode!(header)) <>
            "." <> base64url_encode(Jason.encode!(claims))

        with {:ok, private_key} <- decode_apns_private_key(config.private_key),
             {:ok, signature} <- sign_es256_jwt(signing_input, private_key) do
          jwt = signing_input <> "." <> base64url_encode(signature)
          :persistent_term.put(cache_key, %{jwt: jwt, iat: now})
          {:ok, jwt}
        end
    end
  end

  defp apns_voip_jwt_cache_key(config) do
    {:vibe_notifications_apns_voip_jwt, config.team_id, config.key_id, :erlang.phash2(config.private_key)}
  end

  defp decode_apns_private_key(pem) when is_binary(pem) do
    try do
      case :public_key.pem_decode(pem) do
        [entry | _] ->
          {:ok, :public_key.pem_entry_decode(entry)}

        _ ->
          {:error, :invalid_apns_private_key_pem}
      end
    rescue
      error -> {:error, {:invalid_apns_private_key_pem, error}}
    end
  end

  defp sign_es256_jwt(signing_input, private_key) do
    try do
      der_sig = :public_key.sign(signing_input, :sha256, private_key)
      case :public_key.der_decode(:"ECDSA-Sig-Value", der_sig) do
        {:"ECDSA-Sig-Value", r, s} when is_integer(r) and is_integer(s) ->
          {:ok, <<int_to_fixed_32(r)::binary, int_to_fixed_32(s)::binary>>}

        {r, s} when is_integer(r) and is_integer(s) ->
          {:ok, <<int_to_fixed_32(r)::binary, int_to_fixed_32(s)::binary>>}

        _ ->
          {:error, :invalid_apns_signature}
      end
    rescue
      error -> {:error, {:apns_sign_failed, error}}
    end
  end

  defp int_to_fixed_32(int) when is_integer(int) and int >= 0 do
    bin = :binary.encode_unsigned(int)
    case byte_size(bin) do
      32 -> bin
      size when size < 32 -> :binary.copy(<<0>>, 32 - size) <> bin
      size when size > 32 -> binary_part(bin, size - 32, 32)
    end
  end

  defp apns_voip_payload(data, caller_name, call_type) when is_map(data) do
    aps = %{"content-available" => 1}
    payload =
      data
      |> Map.put_new(:event, "call-start")
      |> Map.put_new(:type, "call-start")
      |> Map.put_new(:nativeCall, true)
      |> Map.put(:callerLabel, caller_name)
      |> Map.put(:callType, if(call_type == "video", do: "video", else: "voice"))
      |> Map.put(:aps, aps)

    {:ok, Jason.encode!(payload)}
  rescue
    error -> {:error, {:apns_payload_encode_failed, error}}
  end

  defp base64url_encode(binary) when is_binary(binary) do
    Base.url_encode64(binary, padding: false)
  end

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
