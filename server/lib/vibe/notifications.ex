defmodule Vibe.Notifications do
  @moduledoc false

  require Logger

  alias Vibe.Accounts

  @expo_push_url "https://exp.host/--/api/v2/push/send"
  @default_message_title "New message"

  def send_incoming_call_push(to_user_id, payload) when is_binary(to_user_id) and is_map(payload) do
    with to_user when not is_nil(to_user) <- Accounts.get_user(to_user_id),
         push_token when is_binary(push_token) <- normalized_push_token(to_user.push_token),
         true <- push_token != "" do
      call_type = normalize_call_type(payload["callType"] || payload["call_type"])
      caller_name = payload["fromUserName"] || payload["from_user_name"] || payload["fromUserId"] || "Unknown"

      message = %{
        to: push_token,
        sound: "default",
        priority: "high",
        title: caller_name,
        body: "Incoming #{call_type} call",
        data: %{
          type: "call-start",
          callId: payload["callId"] || payload["call_id"],
          callType: call_type,
          fromUserId: payload["fromUserId"] || payload["from_user_id"],
          fromUserName: payload["fromUserName"] || payload["from_user_name"],
          fromUserImage: payload["fromUserImage"] || payload["from_user_image"]
        }
      }

      request =
        Finch.build(
          :post,
          @expo_push_url,
          [{"content-type", "application/json"}],
          Jason.encode!(message)
        )

      case Finch.request(request, Vibe.Finch, receive_timeout: 7_000) do
        {:ok, %Finch.Response{status: status}} when status in 200..299 ->
          Logger.info("[Notifications] Incoming call push sent to_user=#{to_user_id}")
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
      sender_name = (sender && (sender.name || sender.username)) || @default_message_title

      data = %{
        type: "new_message",
        chatId: payload["chatId"] || payload["chat_id"],
        messageId: payload["messageId"] || payload["message_id"],
        fromUserId: from_user_id
      }

      message = %{
        to: push_token,
        sound: "default",
        priority: "high",
        title: sender_name,
        body: payload["body"] || "You have a new message",
        data: data
      }

      request =
        Finch.build(
          :post,
          @expo_push_url,
          [{"content-type", "application/json"}],
          Jason.encode!(message)
        )

      Logger.info(
        "[Notifications] Sending message push to_user=#{to_user_id} chat_id=#{data.chatId} message_id=#{data.messageId} from_user=#{from_user_id}"
      )

      case Finch.request(request, Vibe.Finch, receive_timeout: 7_000) do
        {:ok, %Finch.Response{status: status}} when status in 200..299 ->
          Logger.info("[Notifications] Message push sent to_user=#{to_user_id} status=#{status}")
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
end
