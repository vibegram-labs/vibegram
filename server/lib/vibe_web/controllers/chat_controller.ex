defmodule VibeWeb.ChatController do
  use VibeWeb, :controller
  alias Vibe.Chat
  alias Vibe.Accounts
  alias Vibe.Agents
  require Logger

  def create(conn, %{"friendId" => friend_id}) do
    my_id = conn.assigns.current_user.id

    # Validate friend exists to avoid foreign key errors.
    case Accounts.get_user(friend_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "User not found"})

      %{is_agent: true} ->
        if Agents.published_agent_user?(friend_id) do
          do_create_chat(conn, my_id, friend_id)
        else
          conn |> put_status(:forbidden) |> json(%{error: "Agent not available"})
        end

      _user ->
        do_create_chat(conn, my_id, friend_id)
    end
  end

  defp do_create_chat(conn, my_id, friend_id) do
    # Check if chat already exists
    case Chat.find_chat_between_users(my_id, friend_id) do
      id when not is_nil(id) ->
        # Check if user previously deleted this chat
        case Chat.restore_if_deleted(id, my_id) do
          :restored ->
            # Chat was deleted, now restored - return empty messages (fresh start)
            json(conn, %{chatId: id, messages: [], nextCursor: nil, hasMore: false})

          :not_deleted ->
            # Chat exists and wasn't deleted - return only the latest page
            page = Chat.get_messages_for_user_page(id, my_id, limit: 30)
            json(conn, %{chatId: id, messages: page.messages, nextCursor: page.next_cursor, hasMore: page.has_more})
        end

      nil ->
        # Deterministic chat id to make chat creation idempotent and avoid duplicates on concurrent requests.
        # Uses first 12 hex chars of SHA256(sort([my_id, friend_id])).
        chat_id =
          :crypto.hash(:sha256, Enum.sort([my_id, friend_id]) |> Enum.join("|"))
          |> Base.encode16(case: :lower)
          |> binary_part(0, 12)

        try do
          case Chat.create_chat(chat_id, [my_id, friend_id]) do
            {:ok, _chat} ->
              json(conn, %{chatId: chat_id, messages: [], nextCursor: nil, hasMore: false})

            _ ->
              conn |> put_status(500) |> json(%{error: "Failed to create chat"})
          end
        rescue
          Ecto.ConstraintError ->
            # Another request created the chat first; return the existing chat id.
            page = Chat.get_messages_for_user_page(chat_id, my_id, limit: 30)
            json(conn, %{chatId: chat_id, messages: page.messages, nextCursor: page.next_cursor, hasMore: page.has_more})
        end
    end
  end

  def messages(conn, %{"chat_id" => chat_id}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      page =
        Chat.get_messages_for_user_page(
          chat_id,
          user_id,
          limit: parse_limit(conn.params["limit"]),
          before: conn.params["before"]
        )

      json(conn, %{
        messages: page.messages,
        nextCursor: page.next_cursor,
        hasMore: page.has_more
      })
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  def delete_message(conn, %{"chat_id" => chat_id, "message_id" => message_id} = params) do
    user_id = conn.assigns.current_user.id
    for_everyone =
      case Map.get(params, "for_everyone", true) do
        v when v in [true, "true", "1", 1] -> true
        _ -> false
      end

    case Chat.delete_message(chat_id, message_id, user_id, for_everyone) do
      {:ok, _message} ->
        VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "message-deleted", %{
          messageId: message_id,
          deletedBy: user_id,
          forEveryone: for_everyone
        })

        json(conn, %{success: true, messageId: message_id, forEveryone: for_everyone})

      {:error, :invalid_id} ->
        conn |> put_status(:bad_request) |> json(%{error: "Invalid message id"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "Not allowed"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Message not found"})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: inspect(reason)})
    end
  end

  def list_pinned_messages(conn, %{"chat_id" => chat_id}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      pins = Chat.list_pinned_messages(chat_id, user_id)
      Logger.info(
        "[ChatController] list_pinned_messages chat_id=#{chat_id} user_id=#{user_id} count=#{length(pins)}"
      )
      json(conn, %{data: pins})
    else
      Logger.warning(
        "[ChatController] list_pinned_messages forbidden chat_id=#{chat_id} user_id=#{user_id}"
      )
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  def pin_message(conn, %{"chat_id" => chat_id, "message_id" => message_id} = params) do
    user_id = conn.assigns.current_user.id

    pinned =
      case Map.get(params, "pinned", true) do
        v when v in [true, "true", "1", 1] -> true
        _ -> false
      end

    Logger.info(
      "[ChatController] pin_message request chat_id=#{chat_id} user_id=#{user_id} message_id=#{message_id} pinned=#{pinned}"
    )

    case Chat.set_message_pin(chat_id, message_id, user_id, pinned) do
      {:ok, :unpinned} ->
        Logger.info(
          "[ChatController] pin_message ok chat_id=#{chat_id} user_id=#{user_id} message_id=#{message_id} pinned=false"
        )
        json(conn, %{success: true, pinned: false, messageId: message_id})

      {:ok, _pin} ->
        Logger.info(
          "[ChatController] pin_message ok chat_id=#{chat_id} user_id=#{user_id} message_id=#{message_id} pinned=true"
        )
        json(conn, %{success: true, pinned: true, messageId: message_id})

      {:error, :invalid_id} ->
        Logger.warning(
          "[ChatController] pin_message invalid_id chat_id=#{chat_id} user_id=#{user_id} message_id=#{message_id}"
        )
        conn |> put_status(:bad_request) |> json(%{error: "Invalid message id"})

      {:error, :forbidden} ->
        Logger.warning(
          "[ChatController] pin_message forbidden chat_id=#{chat_id} user_id=#{user_id} message_id=#{message_id}"
        )
        conn |> put_status(:forbidden) |> json(%{error: "Not allowed"})

      {:error, :not_found} ->
        Logger.warning(
          "[ChatController] pin_message not_found chat_id=#{chat_id} user_id=#{user_id} message_id=#{message_id}"
        )
        conn |> put_status(:not_found) |> json(%{error: "Message not found"})

      {:error, reason} ->
        Logger.warning(
          "[ChatController] pin_message error chat_id=#{chat_id} user_id=#{user_id} message_id=#{message_id} reason=#{inspect(reason)}"
        )
        conn |> put_status(:bad_request) |> json(%{error: inspect(reason)})
    end
  end

  def index(conn, %{"user_id" => user_id}) do
    current_id = conn.assigns.current_user.id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
      chats =
        case Chat.list_chats(current_id) do
          list when is_list(list) -> list
          _ -> []
        end

      json(conn, chats)
    end
  end

  def mute(conn, %{"chat_id" => chat_id, "muted" => muted}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      {count, _} = Chat.set_muted(chat_id, user_id, muted)
      json(conn, %{success: count > 0})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  def pin(conn, %{"chat_id" => chat_id, "pinned" => pinned}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      {count, _} = Chat.set_pinned(chat_id, user_id, pinned)
      json(conn, %{success: count > 0})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  def mark_unread(conn, %{"chat_id" => chat_id, "unread" => unread}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      {count, _} = Chat.set_marked_unread(chat_id, user_id, unread)
      json(conn, %{success: count > 0})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  def delete(conn, %{"chat_id" => chat_id}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      case Chat.delete_chat(chat_id, user_id) do
        {:ok, _} -> json(conn, %{success: true})
        {:error, reason} -> conn |> put_status(400) |> json(%{error: reason})
      end
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  defp parse_limit(nil), do: nil

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp parse_limit(limit) when is_integer(limit), do: limit
  defp parse_limit(_limit), do: nil
end
