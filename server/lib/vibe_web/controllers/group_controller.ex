defmodule VibeWeb.GroupController do
  use VibeWeb, :controller
  alias Vibe.Accounts
  alias Vibe.Agents
  alias Vibe.Chat

  def create(conn, %{"name" => name, "memberIds" => member_ids}) do
    creator_id = conn.assigns.current_user.id
    invalid_agent =
      Enum.find(member_ids, fn uid ->
        case Accounts.get_user(uid) do
          %{is_agent: true} -> not Agents.published_agent_user?(uid)
          _ -> false
        end
      end)

    if invalid_agent do
      conn |> put_status(:forbidden) |> json(%{error: "Agent not available"})
    else

      case Chat.create_group(creator_id, name, member_ids) do
        {:ok, room} ->
          json(conn, %{
            chatId: room.id,
            type: "group",
            name: room.name,
            creatorId: room.creator_id
          })

        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: "Failed to create group: #{inspect(reason)}"})
      end
    end
  end

  def add_members(conn, %{"id" => chat_id, "memberIds" => member_ids}) do
    requester_id = conn.assigns.current_user.id
    settings = Chat.get_participant_settings(chat_id, requester_id)

    if settings && settings.role in ["owner", "admin"] do
      results = Enum.map(member_ids, fn uid ->
        case Accounts.get_user(uid) do
          %{is_agent: true} ->
            if Agents.published_agent_user?(uid) do
              case Chat.add_member(chat_id, uid, "member") do
                {:ok, _} -> %{userId: uid, added: true}
                _ -> %{userId: uid, added: false}
              end
            else
              %{userId: uid, added: false}
            end

          _ ->
            case Chat.add_member(chat_id, uid, "member") do
              {:ok, _} -> %{userId: uid, added: true}
              _ -> %{userId: uid, added: false}
            end
        end
      end)

      json(conn, %{results: results})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not authorized"})
    end
  end

  def remove_member(conn, %{"id" => chat_id, "user_id" => user_id}) do
    requester_id = conn.assigns.current_user.id
    settings = Chat.get_participant_settings(chat_id, requester_id)

    if settings && settings.role in ["owner", "admin"] do
      case Chat.remove_member(chat_id, user_id) do
        {1, _} -> json(conn, %{success: true})
        _ -> conn |> put_status(400) |> json(%{error: "Failed to remove member"})
      end
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not authorized"})
    end
  end
end
