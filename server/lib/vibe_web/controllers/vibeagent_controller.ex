defmodule VibeWeb.VibeagentController do
  use VibeWeb, :controller

  alias Vibe.AI.AgentBuilder

  def session(conn, _params) do
    user_id = conn.assigns.current_user.id

    case AgentBuilder.session_payload(user_id) do
      {:ok, payload} -> json(conn, payload)
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def chat(conn, %{"message" => message} = params) do
    user_id = conn.assigns.current_user.id
    active_agent_id = params["activeAgentId"] || params["active_agent_id"]

    case AgentBuilder.handle_message(user_id, message, active_agent_id: active_agent_id) do
      {:ok, payload} -> json(conn, payload)
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def chat(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "message is required"})
  end
end
