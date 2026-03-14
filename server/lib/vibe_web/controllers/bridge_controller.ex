defmodule VibeWeb.BridgeController do
  use VibeWeb, :controller

  alias Vibe.ChatBridge
  alias Vibe.RelayRegistry

  def bundle(conn, _params) do
    case ChatBridge.bundle() do
      {:ok, bundle} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(bundle)

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "bridge_bundle_missing"})

      {:error, :invalid_bundle} ->
        conn |> put_status(:internal_server_error) |> json(%{error: "bridge_bundle_invalid"})
    end
  end

  def open_session(conn, params) do
    with {:ok, payload} <- ChatBridge.open_session(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def send(conn, params) do
    with {:ok, payload} <- ChatBridge.send_event(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def poll(conn, params) do
    with {:ok, payload} <- ChatBridge.poll(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def ack(conn, params) do
    with {:ok, payload} <- ChatBridge.ack_event(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def home_snapshot(conn, params) do
    with {:ok, payload} <- ChatBridge.home_snapshot(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def chat_history(conn, params) do
    with {:ok, payload} <- ChatBridge.chat_history(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def peer_key(conn, params) do
    with {:ok, payload} <- ChatBridge.peer_key(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def register_relay(conn, params) do
    user = conn.assigns.current_user

    relay_id =
      normalize_string(params["relayId"] || params["relay_id"]) ||
        "relay_#{:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)}"

    name = normalize_string(params["name"]) || "Relay"
    invite_code = normalize_string(params["inviteCode"] || params["invite_code"])

    # Extract the caller's external IP from the connection
    external_ip = extract_client_ip(conn)

    # Build a bridge URL pointing to the Vibe backend via this relay.
    # For now, the relay user's app acts as the bridge itself,
    # so we return their IP. In the future, this could be a dedicated
    # bridge service running on the relay device.
    bridge_url =
      if external_ip, do: "https://#{external_ip}", else: nil

    # Build the share link descriptor
    descriptor = %{
      id: relay_id,
      host: external_ip,
      port: 443,
      transport: "https",
      origin: "community",
      priority: 50,
      weight: 100,
      baseUrl: bridge_url
    }

    share_data =
      descriptor
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    share_link = "vibe://bridge?d=#{share_data}"

    relay_updates = %{
      invite_code: invite_code,
      name: name,
      user_id: user.id,
      external_ip: external_ip,
      bridge_url: bridge_url,
      share_link: share_link,
      bridge_descriptor: descriptor
    }

    case RelayRegistry.update_relay(relay_id, relay_updates) do
      :ok ->
        :ok

      :not_found ->
        RelayRegistry.register_relay(%{
          relay_id: relay_id,
          user_id: user.id,
          invite_code: invite_code,
          invite_key: nil,
          is_public: false,
          name: name,
          max_peers: 5,
          current_peers: 0,
          region: "unknown",
          started_at: System.system_time(:second),
          external_ip: external_ip,
          bridge_url: bridge_url,
          share_link: share_link,
          bridge_descriptor: descriptor
        })
    end

    VibeWeb.Endpoint.broadcast!("relay:directory", "relay_updated", %{
      relay_id: relay_id,
      name: name,
      current_peers: 0,
      invite_code: invite_code,
      external_ip: external_ip,
      bridge_url: bridge_url,
      share_link: share_link,
      bridge_descriptor: descriptor
    })

    json(conn, %{
      relayId: relay_id,
      userId: user.id,
      externalIp: external_ip,
      bridgeUrl: bridge_url,
      shareLink: share_link,
      shareData: share_data,
      descriptor: descriptor,
      name: name,
      inviteCode: invite_code
    })
  end

  def resolve_relay_bridge(conn, params) do
    invite_code =
      normalize_string(params["inviteCode"] || params["invite_code"])

    with code when is_binary(code) <- invite_code,
         {:ok, relay} <- RelayRegistry.find_by_invite_code(code),
         descriptor when is_map(descriptor) <- relay[:bridge_descriptor] || relay["bridge_descriptor"] do
      json(conn, %{
        inviteCode: code,
        relayId: relay[:relay_id] || relay["relay_id"],
        name: relay[:name] || relay["name"],
        bridgeUrl: relay[:bridge_url] || relay["bridge_url"],
        externalIp: relay[:external_ip] || relay["external_ip"],
        shareLink: relay[:share_link] || relay["share_link"],
        descriptor: descriptor
      })
    else
      nil ->
        conn |> put_status(:bad_request) |> json(%{error: "invite_code_required"})

      :not_found ->
        conn |> put_status(:not_found) |> json(%{error: "relay_not_found"})

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "bridge_not_found"})
    end
  end

  defp extract_client_ip(conn) do
    # Check X-Forwarded-For first (common behind proxies/load balancers)
    forwarded =
      conn
      |> Plug.Conn.get_req_header("x-forwarded-for")
      |> List.first()

    ip =
      case forwarded do
        nil ->
          conn.remote_ip |> :inet.ntoa() |> to_string()

        value ->
          value
          |> String.split(",")
          |> List.first()
          |> String.trim()
      end

    if ip in ["127.0.0.1", "::1", "0.0.0.0"], do: nil, else: ip
  end

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_value), do: nil

  defp render_bridge_error(conn, {:error, :bad_request}) do
    conn |> put_status(:bad_request) |> json(%{error: "bad_request"})
  end

  defp render_bridge_error(conn, {:error, :forbidden}) do
    conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
  end

  defp render_bridge_error(conn, {:error, :not_found}) do
    conn |> put_status(:not_found) |> json(%{error: "not_found"})
  end

  defp render_bridge_error(conn, {:error, :conflict}) do
    conn |> put_status(:conflict) |> json(%{error: "conflict"})
  end

  defp render_bridge_error(conn, {:error, :unprocessable_entity}) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: "unprocessable_entity"})
  end

  defp render_bridge_error(conn, {:error, reason}) do
    conn |> put_status(:bad_request) |> json(%{error: to_string(reason)})
  end
end
