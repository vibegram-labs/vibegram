defmodule Vibe.AI.Tools.Channel do
  @moduledoc """
  Agent tools for channel management: posting, analytics, and scheduling.
  """

  require Logger
  alias Vibe.Chat
  alias Vibe.Notifications

  def post_to_channel(input, user_id) do
    channel_id = input["channel_id"]
    content = input["content"]
    type = input["type"] || "text"
    media_url = input["media_url"]

    # Verify user owns the channel
    case Chat.get_user_role(channel_id, user_id) do
      role when role in ["owner", "admin"] ->
        message_id = Ecto.UUID.generate()
        timestamp = :os.system_time(:millisecond)

        message_attrs = %{
          id: message_id,
          chat_id: channel_id,
          from_id: user_id,
          encrypted_content: content,
          type: type,
          media_url: media_url,
          timestamp: timestamp
        }

        case Chat.add_message(message_attrs) do
          {:ok, _msg} ->
            # Broadcast to channel subscribers
            VibeWeb.Endpoint.broadcast!("chat:#{channel_id}", "message", %{
              "id" => message_id,
              "fromId" => user_id,
              "encryptedContent" => content,
              "type" => type,
              "mediaUrl" => media_url,
              "timestamp" => timestamp
            })

            # Notify subscribers
            Chat.get_participant_ids(channel_id)
            |> Enum.each(fn pid ->
              if pid != user_id do
                VibeWeb.Endpoint.broadcast!("user:#{pid}", "new_message", %{
                  chat_id: channel_id,
                  from_id: user_id,
                  message_id: message_id,
                  timestamp: timestamp
                })

                _ =
                  Notifications.send_message_push(pid, %{
                    "chat_id" => channel_id,
                    "from_id" => user_id,
                    "message_id" => message_id
                  })
              end
            end)

            %{success: true, message: "Posted to channel", message_id: message_id}

          {:error, reason} ->
            %{error: "Failed to post: #{inspect(reason)}"}
        end

      _ ->
        %{error: "You don't own this channel"}
    end
  end

  def get_analytics(input, user_id) do
    channel_id = input["channel_id"]

    # Verify user has access
    case Chat.get_user_role(channel_id, user_id) do
      role when role in ["owner", "admin"] ->
        analytics = Chat.get_channel_analytics(channel_id)
        %{success: true, analytics: analytics}

      _ ->
        %{error: "You don't have access to this channel's analytics"}
    end
  end

  def schedule_post(input, user_id) do
    channel_id = input["channel_id"]

    # Verify user owns the channel
    case Chat.get_user_role(channel_id, user_id) do
      role when role in ["owner", "admin"] ->
        scheduled_at = case DateTime.from_iso8601(input["scheduled_at"]) do
          {:ok, dt, _} -> dt
          _ -> nil
        end

        if is_nil(scheduled_at) do
          %{error: "Invalid scheduled_at datetime. Use ISO8601 format."}
        else
          attrs = %{
            channel_id: channel_id,
            user_id: user_id,
            content: input["content"],
            type: input["type"] || "text",
            media_url: input["media_url"],
            scheduled_at: scheduled_at
          }

          case Vibe.Scheduler.schedule_post(attrs) do
            {:ok, post} ->
              %{success: true, message: "Post scheduled", post_id: post.id, scheduled_at: to_string(post.scheduled_at)}

            {:error, reason} ->
              %{error: "Failed to schedule: #{inspect(reason)}"}
          end
        end

      _ ->
        %{error: "You don't own this channel"}
    end
  end
end
