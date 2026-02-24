defmodule VibeWeb.UserSocket do
  use Phoenix.Socket

  # A Socket handler
  #
  # It's possible to control the websocket connection and
  # assign values that can be accessed by your channel topics.

  ## Channels
  channel "user:*", VibeWeb.UserChannel # Personal channel for calls/notifications
  channel "chat:*", VibeWeb.ChatChannel # Chat rooms
  channel "agent:*", VibeWeb.AgentChannel # AI Agent streaming
  channel "relay:*", VibeWeb.RelayChannel # VibeNet peer relay network

  # Socket params are passed from the client and can
  # be used to verify and authenticate a user. After
  # verification, you can put default assigns into
  # the socket that will be set for all channels, ie
  #
  #     {:ok, assign(socket, :user_id, verified_user_id)}
  #
  # To deny connection, return `:error` or `{:error, term}`.
  @impl true
  def connect(%{"token" => "undefined"}, _socket, _connect_info) do
    # Client hasn't logged in yet, refuse cleanly
    :error
  end
  def connect(params, socket, connect_info) do
    # Priority: Authorization header (mobile clients) > query param (web client).
    # Mobile clients send the token as a Bearer header to avoid leaking it in
    # URL query strings (visible in logs, proxies, referer headers, etc.).
    token =
      case extract_bearer_from_connect_info(connect_info) do
        nil -> params["token"]
        header_token -> header_token
      end

    case token do
      nil ->
        :error
      t when is_binary(t) and t != "" ->
        case Vibe.Accounts.get_user_by_token(t) do
          {:ok, user} ->
            {:ok, assign(socket, :user_id, user.id)}
          _ ->
            :error
        end
      _ ->
        :error
    end
  end

  # Extract the Bearer token from the x_headers forwarded via connect_info.
  defp extract_bearer_from_connect_info(%{x_headers: headers}) when is_list(headers) do
    Enum.find_value(headers, fn
      {"authorization", "Bearer " <> token} -> String.trim(token)
      _ -> nil
    end)
  end
  defp extract_bearer_from_connect_info(_), do: nil

  # Socket id's are topics that allow you to identify all sockets for a given user:
  #
  #     def id(socket), do: "user_socket:#{socket.assigns.user_id}"
  #
  # Would allow you to broadcast a "disconnect" event and terminate
  # all active sockets and channels for a given user:
  #
  #     Elixir.VibeWeb.Endpoint.broadcast("user_socket:#{user.id}", "disconnect", %{})
  #
  # Returning `nil` makes this socket anonymous.
  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
