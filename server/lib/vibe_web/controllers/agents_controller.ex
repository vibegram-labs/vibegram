defmodule VibeWeb.AgentsController do
  use VibeWeb, :controller

  alias Vibe.Agents
  alias Vibe.AI.StandaloneAgent

  def index(conn, _params) do
    owner_id = conn.assigns.current_user.id
    quota = Agents.quota_for_user(owner_id)

    items =
      owner_id
      |> Agents.list_agents()
      |> Enum.map(&Agents.agent_payload/1)

    json(conn, %{items: items, quota: quota})
  end

  def create(conn, params) do
    owner_id = conn.assigns.current_user.id

    case Agents.create_agent(owner_id, params) do
      {:ok, agent, secret} ->
        json(conn, %{agent: Agents.agent_payload(agent, quota: Agents.quota_for_user(owner_id)), secret: secret})

      {:error, :quota_exceeded} ->
        conn |> put_status(:forbidden) |> json(%{error: "Agent limit reached"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def show(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    case Agents.get_agent(id, owner_id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Agent not found"})
      agent -> json(conn, Agents.agent_payload(agent, quota: Agents.quota_for_user(owner_id)))
    end
  end

  def update(conn, %{"id" => id} = params) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, updated} <- Agents.update_agent(agent, Map.delete(params, "id"), owner_id) do
      json(conn, Agents.agent_payload(updated, quota: Agents.quota_for_user(owner_id)))
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Agent not found"})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def publish(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, updated} <- Agents.publish_agent(agent, owner_id) do
      json(conn, Agents.agent_payload(updated, quota: Agents.quota_for_user(owner_id)))
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Agent not found"})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def rotate_secret(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, updated, secret} <- Agents.rotate_secret(agent, owner_id) do
      json(conn, %{agent: Agents.agent_payload(updated), secret: secret})
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Agent not found"})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def deliveries(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    case Agents.get_agent(id, owner_id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Agent not found"})
      agent -> json(conn, Agents.list_delivery_data(agent))
    end
  end

  def delete(conn, %{"id" => id}) do
    owner_id = conn.assigns.current_user.id

    with %{} = agent <- Agents.get_agent(id, owner_id),
         {:ok, _} <- Agents.archive_agent(agent, owner_id) do
      json(conn, %{success: true})
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Agent not found"})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def invoke(conn, %{"identifier" => identifier} = params) do
    secret = List.first(get_req_header(conn, "x-vibe-agent-secret"))

    with %{} = agent <- Agents.get_invoke_target(identifier),
         :ok <- ensure_agent_published(agent),
         :ok <- ensure_secret(agent, secret),
         {:ok, result} <- StandaloneAgent.invoke(agent, params),
         {:ok, invocation} <-
           Agents.record_invocation(agent, %{
             source: params["source"] || "external",
             event_id: params["eventId"] || params["event_id"],
             vibe_chat_id: params["vibeChatId"] || params["vibe_chat_id"],
             external_user_id: params["externalUserId"] || params["external_user_id"],
             request_payload: Map.drop(params, ["identifier"]),
             response_payload: result,
             status: "completed"
           }) do
      if is_binary(agent.callback_url) and String.trim(agent.callback_url) != "" do
        _ = Agents.create_delivery_event(agent, invocation, "agent.invocation.completed", result)
      end

      json(conn, result |> Map.put(:success, true) |> Map.put(:invocationId, invocation.id))
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agent not found"})

      {:error, :agent_unavailable} ->
        conn |> put_status(:forbidden) |> json(%{error: "Agent unavailable"})

      {:error, :invalid_secret} ->
        conn |> put_status(:unauthorized) |> json(%{error: "Invalid secret"})

      {:error, :chat_not_attached} ->
        conn |> put_status(:forbidden) |> json(%{error: "Agent not attached to target chat"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  defp ensure_agent_published(%{status: "published"}), do: :ok
  defp ensure_agent_published(_agent), do: {:error, :agent_unavailable}

  defp ensure_secret(agent, secret) do
    if Agents.verify_secret(agent, secret), do: :ok, else: {:error, :invalid_secret}
  end
end
