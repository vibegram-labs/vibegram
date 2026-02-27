defmodule VibeWeb.UserChannel do
  use VibeWeb, :channel
  require Logger
  alias VibeWeb.Presence
  alias Vibe.Accounts
  alias Vibe.Notifications

  @impl true
  def join("user:" <> user_id, _payload, socket) do
    if authorized?(socket, user_id) do
      send(self(), :after_join)
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  alias Vibe.Chat

  @impl true
  def handle_info(:after_join, socket) do
    user_id = socket.assigns.user_id
    user = Accounts.get_user(user_id)

    # Track this user's presence immediately (fast, no DB)
    if user && user.show_online_status do
      {:ok, _} = Presence.track(socket, user_id, %{
        online_at: System.system_time(:second)
      })
    end

    # Heavy work (list_chats = 6 DB queries) runs in a background Task
    # so the channel process stays responsive for incoming messages
    channel_pid = self()
    show_online = user && user.show_online_status

    Task.start(fn ->
      chats = Chat.list_chats(user_id)
      friend_ids = Enum.map(chats, fn c -> c[:friendId] end) |> Enum.reject(&is_nil/1)

      # Notify friends I am online
      if show_online do
        Enum.each(friend_ids, fn fid ->
          VibeWeb.Endpoint.broadcast("user:#{fid}", "friend-online", %{
            userId: user_id,
            user_id: user_id
          })
        end)
      end

      # Find which friends are online
      online_friend_ids = Enum.filter(friend_ids, fn fid ->
        VibeWeb.Presence.list("user:#{fid}") |> map_size() > 0
      end)

      # Send results back to the channel process (push must happen there)
      send(channel_pid, {:after_join_complete, friend_ids, online_friend_ids})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:after_join_complete, friend_ids, online_friend_ids}, socket) do
    # Cache friend_ids so terminate/2 doesn't need to re-fetch
    socket = assign(socket, :friend_ids, friend_ids)

    push(socket, "initial-presence", %{
      onlineFriendIds: online_friend_ids,
      online_friend_ids: online_friend_ids
    })

    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    user_id = socket.assigns.user_id
    # Use cached friend_ids from :after_join_complete (avoids re-running list_chats)
    cached_friend_ids = socket.assigns[:friend_ids]

    # Run all terminate work asynchronously so the process exits immediately
    Task.start(fn ->
      user = Accounts.get_user(user_id)
      last_seen = DateTime.utc_now()

      if user do
        _ = Accounts.update_user(user, %{last_seen: last_seen})
      end

      friend_ids =
        case cached_friend_ids do
          ids when is_list(ids) -> ids
          _ ->
            # Fallback: fetch if cache wasn't populated (e.g. very short session)
            chats = Chat.list_chats(user_id)
            Enum.map(chats, fn c -> c[:friendId] end) |> Enum.reject(&is_nil/1)
        end

      if user && user.show_online_status do
        Enum.each(friend_ids, fn fid ->
          VibeWeb.Endpoint.broadcast("user:#{fid}", "friend-offline", %{
            userId: user_id,
            user_id: user_id,
            lastSeen: if(user.show_last_seen, do: last_seen, else: nil),
            last_seen: if(user.show_last_seen, do: last_seen, else: nil),
            lastSeenMs:
              if(user.show_last_seen, do: DateTime.to_unix(last_seen, :millisecond), else: nil),
            last_seen_ms:
              if(user.show_last_seen, do: DateTime.to_unix(last_seen, :millisecond), else: nil)
          })
        end)
      end
    end)

    :ok
  end

  @impl true
  def handle_in("call-start", %{"toUserId" => to_user_id} = payload, socket) do
    caller = Accounts.get_user(socket.assigns.user_id)

    call_id =
      payload["callId"] ||
        payload["call_id"] ||
        "call_#{System.system_time(:millisecond)}_#{System.unique_integer([:positive])}"

    call_type =
      case String.downcase(to_string(payload["callType"] || payload["call_type"] || "voice")) do
        "video" -> "video"
        _ -> "voice"
      end

    from_user_name =
      payload["fromUserName"] ||
        payload["from_user_name"] ||
        (caller && (caller.name || caller.username)) ||
        socket.assigns.user_id

    from_user_image =
      payload["fromUserImage"] ||
        payload["from_user_image"] ||
        (caller && caller.profile_image)

    enriched_payload =
      payload
      |> Map.put("fromUserId", socket.assigns.user_id)
      |> Map.put("from_user_id", socket.assigns.user_id)
      |> Map.put("callId", call_id)
      |> Map.put("call_id", call_id)
      |> Map.put("callType", call_type)
      |> Map.put("call_type", call_type)
      |> Map.put("fromUserName", from_user_name)
      |> Map.put("from_user_name", from_user_name)
      |> Map.put("fromUserImage", from_user_image)
      |> Map.put("from_user_image", from_user_image)

    VibeWeb.Endpoint.broadcast!("user:#{to_user_id}", "call-start", enriched_payload)

    recipient_online = map_size(VibeWeb.Presence.list("user:#{to_user_id}")) > 0
    Logger.info(
      "[UserChannel] call push dispatch to_user=#{to_user_id} call_id=#{call_id} recipient_online=#{recipient_online}"
    )
    Task.start(fn ->
      _ = Notifications.send_incoming_call_push(to_user_id, enriched_payload)
    end)

    {:reply,
     {:ok,
      %{
        "callId" => call_id,
        "call_id" => call_id,
        "callType" => call_type,
        "call_type" => call_type,
        "recipientOnline" => recipient_online
      }}, socket}
  end

  @impl true
  def handle_in("call-accepted", %{"toUserId" => to_user_id} = payload, socket) do
    payload = Map.put(payload, "fromUserId", socket.assigns.user_id)
    VibeWeb.Endpoint.broadcast!("user:#{to_user_id}", "call-accepted", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("call-end", %{"toUserId" => to_user_id} = payload, socket) do
    VibeWeb.Endpoint.broadcast!("user:#{to_user_id}", "call-end", payload)
    {:noreply, socket}
  end

  # Join Requests
  @impl true
  def handle_in("call-join-request", %{"toUserId" => to_user_id} = payload, socket) do
    payload = Map.put(payload, "fromId", socket.assigns.user_id) # Chat.tsx expects fromId
    VibeWeb.Endpoint.broadcast!("user:#{to_user_id}", "call-join-request", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("call-join-accepted", %{"toUserId" => to_user_id} = payload, socket) do
    payload = Map.put(payload, "fromId", socket.assigns.user_id)
    VibeWeb.Endpoint.broadcast!("user:#{to_user_id}", "call-join-accepted", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("call-join-rejected", %{"toUserId" => to_user_id} = payload, socket) do
     payload = Map.put(payload, "fromId", socket.assigns.user_id)
     VibeWeb.Endpoint.broadcast!("user:#{to_user_id}", "call-join-rejected", payload)
     {:noreply, socket}
  end

  # Fallback Voice Stream (Heavy? Consider dedicated socket/UDP in future)
  @impl true
  def handle_in("voice-stream", %{"toUserId" => to_user_id} = payload, socket) do
     VibeWeb.Endpoint.broadcast!("user:#{to_user_id}", "voice-stream", payload)
     {:noreply, socket}
  end

  # WebRTC Signaling (SDP offers/answers, ICE candidates)
  @impl true
  def handle_in("webrtc-signal", %{"toUserId" => to_user_id} = payload, socket) do
    payload = Map.put(payload, "fromUserId", socket.assigns.user_id)
    VibeWeb.Endpoint.broadcast!("user:#{to_user_id}", "webrtc-signal", payload)
    {:noreply, socket}
  end

  defp authorized?(socket, user_id) do
    socket.assigns.user_id == user_id
  end
end
