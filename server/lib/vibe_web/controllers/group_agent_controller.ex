defmodule VibeWeb.GroupAgentController do
  use VibeWeb, :controller
  alias Vibe.Chat
  alias Vibe.Chat.GroupAgent

  # POST /api/group/:id/agent — Create/configure agent (owner/admin only)
  def create(conn, %{"id" => chat_id} = params) do
    user_id = conn.assigns.current_user.id

    case authorize_admin(chat_id, user_id) do
      :ok ->
        # Check if agent already exists
        case GroupAgent.get_by_chat(chat_id) do
          nil ->
            attrs = %{
              chat_id: chat_id,
              name: params["name"] || "Vibe AI",
              system_prompt: params["systemPrompt"] || params["system_prompt"],
              avatar_url: params["avatarUrl"] || params["avatar_url"],
              enabled: Map.get(params, "enabled", true),
              created_by: user_id
            }

            case GroupAgent.create(attrs) do
              {:ok, agent} ->
                json(conn, %{
                  id: agent.id,
                  chatId: agent.chat_id,
                  name: agent.name,
                  systemPrompt: agent.system_prompt,
                  avatarUrl: agent.avatar_url,
                  enabled: agent.enabled,
                  createdBy: agent.created_by
                })

              {:error, changeset} ->
                conn |> put_status(422) |> json(%{error: format_errors(changeset)})
            end

          _existing ->
            conn |> put_status(409) |> json(%{error: "Agent already exists for this group. Use PUT to update."})
        end

      {:error, reason} ->
        conn |> put_status(:forbidden) |> json(%{error: reason})
    end
  end

  # GET /api/group/:id/agent — Get agent config (any participant)
  def show(conn, %{"id" => chat_id}) do
    user_id = conn.assigns.current_user.id

    unless Chat.is_participant?(chat_id, user_id) do
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    else
      case GroupAgent.get_by_chat(chat_id) do
        nil ->
          conn |> put_status(404) |> json(%{error: "No agent configured"})

        agent ->
          json(conn, %{
            id: agent.id,
            chatId: agent.chat_id,
            name: agent.name,
            systemPrompt: agent.system_prompt,
            avatarUrl: agent.avatar_url,
            enabled: agent.enabled,
            createdBy: agent.created_by
          })
      end
    end
  end

  # PUT /api/group/:id/agent — Update agent (owner/admin only)
  def update(conn, %{"id" => chat_id} = params) do
    user_id = conn.assigns.current_user.id

    case authorize_admin(chat_id, user_id) do
      :ok ->
        case GroupAgent.get_by_chat(chat_id) do
          nil ->
            conn |> put_status(404) |> json(%{error: "No agent configured"})

          agent ->
            attrs = %{}
            attrs = if params["name"], do: Map.put(attrs, :name, params["name"]), else: attrs
            attrs = if params["systemPrompt"] || params["system_prompt"] do
              Map.put(attrs, :system_prompt, params["systemPrompt"] || params["system_prompt"])
            else
              attrs
            end
            attrs = if params["avatarUrl"] || params["avatar_url"] do
              Map.put(attrs, :avatar_url, params["avatarUrl"] || params["avatar_url"])
            else
              attrs
            end
            attrs = if Map.has_key?(params, "enabled") do
              Map.put(attrs, :enabled, params["enabled"])
            else
              attrs
            end

            case GroupAgent.update(agent, attrs) do
              {:ok, updated} ->
                json(conn, %{
                  id: updated.id,
                  chatId: updated.chat_id,
                  name: updated.name,
                  systemPrompt: updated.system_prompt,
                  avatarUrl: updated.avatar_url,
                  enabled: updated.enabled,
                  createdBy: updated.created_by
                })

              {:error, changeset} ->
                conn |> put_status(422) |> json(%{error: format_errors(changeset)})
            end
        end

      {:error, reason} ->
        conn |> put_status(:forbidden) |> json(%{error: reason})
    end
  end

  # DELETE /api/group/:id/agent — Remove agent (owner/admin only)
  def delete(conn, %{"id" => chat_id}) do
    user_id = conn.assigns.current_user.id

    case authorize_admin(chat_id, user_id) do
      :ok ->
        case GroupAgent.get_by_chat(chat_id) do
          nil ->
            conn |> put_status(404) |> json(%{error: "No agent configured"})

          agent ->
            case GroupAgent.delete(agent) do
              {:ok, _} ->
                # Also clear the agent's memory
                Vibe.Chat.GroupAgentMemory.delete_by_chat(chat_id)
                json(conn, %{success: true})

              {:error, _} ->
                conn |> put_status(500) |> json(%{error: "Failed to remove agent"})
            end
        end

      {:error, reason} ->
        conn |> put_status(:forbidden) |> json(%{error: reason})
    end
  end

  # ── Helpers ──

  defp authorize_admin(chat_id, user_id) do
    settings = Chat.get_participant_settings(chat_id, user_id)

    if settings && settings.role in ["owner", "admin"] do
      :ok
    else
      {:error, "Not authorized. Only group owner or admin can manage the agent."}
    end
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
    |> Enum.join("; ")
  end
  defp format_errors(error), do: inspect(error)
end
