defmodule Vibe.Agents do
  import Ecto.Query, warn: false
  import Plug.Crypto, only: [secure_compare: 2]

  alias Vibe.Repo
  alias Vibe.Accounts
  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.AgentConversation
  alias Vibe.AgentDeliveryEvent
  alias Vibe.AgentInvocation
  alias Vibe.Chat.Participant
  alias Vibe.Chat.Room
  alias Vibe.Subscriptions

  @builder_kind "vibeagent_builder"
  @reserved_usernames ["vibeagent"]
  @default_output_modes ["text"]

  def default_output_modes, do: @default_output_modes

  def default_enabled_tools do
    Vibe.AI.ToolRegistry.default_tool_ids()
  end

  def agent_limit_for_user(user_id), do: Subscriptions.agent_limit_for_user(user_id)

  def quota_for_user(user_id) do
    used =
      Repo.one(
        from a in Agent,
          where: a.owner_user_id == ^user_id and a.status != "archived",
          select: count(a.id)
      ) || 0

    limit = agent_limit_for_user(user_id)
    %{used: used, limit: limit, remaining: max(limit - used, 0)}
  end

  def list_agents(owner_user_id) do
    Repo.all(
      from a in Agent,
        where: a.owner_user_id == ^owner_user_id and a.status != "archived",
        preload: [:agent_user],
        order_by: [desc: a.updated_at]
    )
  end

  def get_agent(id, owner_user_id \\ nil)

  def get_agent(id, nil) when is_binary(id) do
    Repo.one(from a in Agent, where: a.id == ^id, preload: [:agent_user])
  end

  def get_agent(id, owner_user_id) when is_binary(id) do
    Repo.one(
      from a in Agent,
        where: a.id == ^id and a.owner_user_id == ^owner_user_id,
        preload: [:agent_user]
    )
  end

  def get_agent_by_shadow_user(user_id) when is_binary(user_id) do
    Repo.one(from a in Agent, where: a.agent_user_id == ^user_id, preload: [:agent_user])
  end

  def get_agent_by_username(username) when is_binary(username) do
    normalized = normalize_username(username)

    Repo.one(
      from a in Agent,
        join: u in User,
        on: u.id == a.agent_user_id,
        where: fragment("LOWER(?)", u.username) == ^normalized,
        preload: [agent_user: u]
    )
  end

  def get_invoke_target(identifier) when is_binary(identifier) do
    get_agent(identifier) || get_agent_by_username(identifier)
  end

  def create_agent(owner_user_id, attrs \\ %{}) do
    with :ok <- ensure_quota(owner_user_id),
         {:ok, secret_tuple} <- generate_secret_tuple(),
         {:ok, shadow_user} <- create_shadow_user(owner_user_id, attrs),
         {:ok, agent} <-
           %Agent{}
           |> Agent.changeset(%{
             owner_user_id: owner_user_id,
             agent_user_id: shadow_user.id,
             status: "draft",
             display_name: display_name_from_attrs(attrs),
             system_prompt: string_attr(attrs, "system_prompt") || "",
             persona: string_attr(attrs, "persona"),
             avatar_url: string_attr(attrs, "avatar_url"),
             welcome_message: string_attr(attrs, "welcome_message"),
             enabled_tools: normalize_enabled_tools(attrs["enabled_tools"] || attrs[:enabled_tools]),
             output_modes: normalize_output_modes(attrs["output_modes"] || attrs[:output_modes]),
             voice_provider: string_attr(attrs, "voice_provider"),
             voice_profile: string_attr(attrs, "voice_profile") || "alloy",
             callback_url: normalize_callback_url(attrs["callback_url"] || attrs[:callback_url]),
             webhook_secret_hash: secret_tuple.hash,
             webhook_secret_encrypted: secret_tuple.encrypted,
             secret_hint: secret_tuple.hint
           })
           |> Repo.insert() do
      {:ok, Repo.preload(agent, :agent_user), secret_tuple.secret}
    end
  end

  def update_agent(%Agent{} = agent, attrs, owner_user_id) do
    if agent.owner_user_id != owner_user_id do
      {:error, :forbidden}
    else
      Repo.transaction(fn ->
        maybe_update_shadow_user!(agent, attrs)

        agent
        |> Agent.changeset(%{
          display_name: display_name_from_attrs(attrs, agent.display_name),
          system_prompt: Map.get(attrs, "system_prompt", Map.get(attrs, :system_prompt, agent.system_prompt || "")),
          persona: map_get(attrs, "persona", agent.persona),
          avatar_url: map_get(attrs, "avatar_url", agent.avatar_url),
          welcome_message: map_get(attrs, "welcome_message", agent.welcome_message),
          enabled_tools: normalize_enabled_tools(Map.get(attrs, "enabled_tools", Map.get(attrs, :enabled_tools, agent.enabled_tools))),
          output_modes: normalize_output_modes(Map.get(attrs, "output_modes", Map.get(attrs, :output_modes, agent.output_modes))),
          voice_provider: map_get(attrs, "voice_provider", agent.voice_provider),
          voice_profile: map_get(attrs, "voice_profile", agent.voice_profile),
          callback_url: normalize_callback_url(Map.get(attrs, "callback_url", Map.get(attrs, :callback_url, agent.callback_url))),
          status: normalize_status_update(agent, attrs)
        })
        |> Repo.update!()
      end)
      |> case do
        {:ok, updated} -> {:ok, Repo.preload(updated, :agent_user)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def publish_agent(%Agent{} = agent, owner_user_id) do
    if agent.owner_user_id != owner_user_id do
      {:error, :forbidden}
    else
      cond do
        String.trim(agent.system_prompt || "") == "" ->
          {:error, :missing_system_prompt}

        Enum.empty?(agent.output_modes || []) ->
          {:error, :missing_output_modes}

        "voice" in (agent.output_modes || []) and is_nil(System.get_env("OPENAI_API_KEY")) ->
          {:error, :voice_unavailable}

        true ->
          agent
          |> Agent.changeset(%{status: "published", published_at: DateTime.utc_now()})
          |> Repo.update()
          |> case do
            {:ok, updated} -> {:ok, Repo.preload(updated, :agent_user)}
            error -> error
          end
      end
    end
  end

  def rotate_secret(%Agent{} = agent, owner_user_id) do
    if agent.owner_user_id != owner_user_id do
      {:error, :forbidden}
    else
      with {:ok, secret_tuple} <- generate_secret_tuple(),
           {:ok, updated} <-
             agent
             |> Agent.changeset(%{
               webhook_secret_hash: secret_tuple.hash,
               webhook_secret_encrypted: secret_tuple.encrypted,
               secret_hint: secret_tuple.hint
             })
             |> Repo.update() do
        {:ok, Repo.preload(updated, :agent_user), secret_tuple.secret}
      end
    end
  end

  def archive_agent(%Agent{} = agent, owner_user_id) do
    if agent.owner_user_id != owner_user_id do
      {:error, :forbidden}
    else
      Repo.transaction(fn ->
        from(p in Participant, where: p.user_id == ^agent.agent_user_id)
        |> Repo.delete_all()

        agent
        |> Agent.changeset(%{status: "archived", callback_url: nil, last_invoked_at: agent.last_invoked_at})
        |> Repo.update!()
      end)
      |> case do
        {:ok, updated} -> {:ok, Repo.preload(updated, :agent_user)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def attached_chats(%Agent{} = agent) do
    Repo.all(
      from r in Room,
        join: p in Participant,
        on: p.chat_id == r.id,
        where: p.user_id == ^agent.agent_user_id,
        select: %{
          chatId: r.id,
          type: r.type,
          name: r.name,
          avatarUrl: r.avatar_url
        }
    )
  end

  def published_agent_user?(user_id) when is_binary(user_id) do
    match?(%Agent{status: "published"}, get_agent_by_shadow_user(user_id))
  end

  def verify_secret(%Agent{} = agent, secret) when is_binary(secret) do
    expected = hash_secret(secret)
    secure_compare(expected, agent.webhook_secret_hash || "")
  end

  def verify_secret(_agent, _secret), do: false

  def callback_signing_secret(%Agent{webhook_secret_encrypted: encrypted}) when is_binary(encrypted) do
    decrypt_secret(encrypted)
  end

  def callback_signing_secret(_agent), do: {:error, :missing_encrypted_secret}

  def record_invocation(%Agent{} = agent, attrs) do
    result =
      %AgentInvocation{}
      |> AgentInvocation.changeset(Map.put(attrs, :agent_id, agent.id))
      |> Repo.insert()

    case result do
      {:ok, invocation} ->
        _ =
          agent
          |> Agent.changeset(%{last_invoked_at: DateTime.utc_now()})
          |> Repo.update()

        {:ok, invocation}

      {:error, %Ecto.Changeset{errors: [event_id: _ | _]}} ->
        event_id = Map.get(attrs, :event_id) || Map.get(attrs, "event_id")

        Repo.one(
          from i in AgentInvocation,
            where: i.agent_id == ^agent.id and i.event_id == ^event_id,
            limit: 1
        )
        |> case do
          nil -> result
          invocation -> {:ok, invocation}
        end

      _ ->
        result
    end
  end

  def list_delivery_data(%Agent{} = agent) do
    invocations =
      Repo.all(
        from i in AgentInvocation,
          where: i.agent_id == ^agent.id,
          order_by: [desc: i.inserted_at],
          limit: 50
      )
      |> Enum.map(fn invocation ->
        %{
          id: invocation.id,
          source: invocation.source,
          eventId: invocation.event_id,
          vibeChatId: invocation.vibe_chat_id,
          externalUserId: invocation.external_user_id,
          requestPayload: invocation.request_payload,
          responsePayload: invocation.response_payload,
          status: invocation.status,
          error: invocation.error,
          insertedAt: invocation.inserted_at
        }
      end)

    deliveries =
      Repo.all(
        from d in AgentDeliveryEvent,
          where: d.agent_id == ^agent.id,
          order_by: [desc: d.inserted_at],
          limit: 50
      )
      |> Enum.map(fn delivery ->
        %{
          id: delivery.id,
          invocationId: delivery.invocation_id,
          eventType: delivery.event_type,
          targetUrl: delivery.target_url,
          requestBody: delivery.request_body,
          responseCode: delivery.response_code,
          status: delivery.status,
          attemptCount: delivery.attempt_count,
          lastError: delivery.last_error,
          insertedAt: delivery.inserted_at
        }
      end)

    %{invocations: invocations, deliveries: deliveries}
  end

  def create_delivery_event(%Agent{} = agent, %AgentInvocation{} = invocation, event_type, body) do
    target_url = String.trim(agent.callback_url || "")

    cond do
      target_url == "" ->
        {:error, :missing_callback}

      true ->
        %AgentDeliveryEvent{}
        |> AgentDeliveryEvent.changeset(%{
          agent_id: agent.id,
          invocation_id: invocation.id,
          event_type: event_type,
          target_url: target_url,
          request_body: body,
          status: "pending",
          attempt_count: 0
        })
        |> Repo.insert()
    end
  end

  def due_delivery_events(limit \\ 50) do
    Repo.all(
      from d in AgentDeliveryEvent,
        where: d.status in ["pending", "retrying"],
        order_by: [asc: d.inserted_at],
        limit: ^limit,
        preload: [:agent, :invocation]
    )
  end

  def update_delivery_event(%AgentDeliveryEvent{} = event, attrs) do
    event
    |> AgentDeliveryEvent.changeset(attrs)
    |> Repo.update()
  end

  def get_or_create_builder_session(user_id) do
    query =
      from c in AgentConversation,
        where:
          c.user_id == ^user_id and
            fragment("?->>'kind' = ?", c.metadata, ^@builder_kind),
        order_by: [desc: c.updated_at],
        limit: 1

    case Repo.one(query) do
      nil ->
        AgentConversation.create(user_id, "Vibe Agent Builder")
        |> case do
          {:ok, conv} ->
            conv
            |> AgentConversation.changeset(%{metadata: %{"kind" => @builder_kind, "draft_state" => %{}}})
            |> Repo.update()

          error ->
            error
        end

      conv ->
        {:ok, conv}
    end
  end

  def update_builder_session(%AgentConversation{} = conversation, attrs) do
    conversation
    |> AgentConversation.changeset(attrs)
    |> Repo.update()
  end

  def agent_payload(%Agent{} = agent, opts \\ []) do
    quota = Keyword.get(opts, :quota)
    agent = Repo.preload(agent, :agent_user)

    payload = %{
      id: agent.id,
      userId: agent.agent_user_id,
      username: agent.agent_user && agent.agent_user.username,
      displayName: agent.display_name,
      status: agent.status,
      systemPrompt: agent.system_prompt,
      persona: agent.persona,
      avatarUrl: agent.avatar_url,
      welcomeMessage: agent.welcome_message,
      enabledTools: agent.enabled_tools || [],
      outputModes: agent.output_modes || [],
      voiceProvider: agent.voice_provider,
      voiceProfile: agent.voice_profile,
      callbackUrl: agent.callback_url,
      secretHint: agent.secret_hint,
      publishedAt: agent.published_at,
      lastInvokedAt: agent.last_invoked_at,
      attachedChats: attached_chats(agent)
    }

    if quota, do: Map.put(payload, :quota, quota), else: payload
  end

  def agent_id_for_user(user_id) when is_binary(user_id) do
    case get_agent_by_shadow_user(user_id) do
      %Agent{id: id} -> id
      _ -> nil
    end
  end

  def visible_to_invite?(%Agent{status: "published"}), do: true
  def visible_to_invite?(_), do: false

  def builder_kind, do: @builder_kind

  def reserved_username?(username) do
    normalize_username(username) in @reserved_usernames
  end

  def normalize_username(username) when is_binary(username) do
    username
    |> String.trim()
    |> String.trim_leading("@")
    |> String.downcase()
  end

  def normalize_username(_), do: ""

  def normalize_enabled_tools(raw_tools) do
    raw_tools
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.filter(&(&1 in Vibe.AI.ToolRegistry.tool_ids()))
    |> Enum.uniq()
    |> case do
      [] -> default_enabled_tools()
      tools -> tools
    end
  end

  def normalize_output_modes(raw_modes) do
    raw_modes
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.filter(&(&1 in ~w[text media voice]))
    |> Enum.uniq()
    |> case do
      [] -> @default_output_modes
      modes -> modes
    end
  end

  defp ensure_quota(owner_user_id) do
    quota = quota_for_user(owner_user_id)
    if quota.used >= quota.limit, do: {:error, :quota_exceeded}, else: :ok
  end

  defp create_shadow_user(_owner_user_id, attrs) do
    display_name = display_name_from_attrs(attrs)
    username = requested_or_generated_username(display_name, attrs)
    user_id = UUID.uuid4()

    Accounts.create_user(%{
      "id" => user_id,
      "username" => username,
      "name" => display_name,
      "password_hash" => "agent:#{user_id}",
      "device_id" => "agent:#{user_id}",
      "public_key" => "agent",
      "encrypted_private_key" => "agent",
      "identity_key" => "agent",
      "secure_id" => "agent:#{user_id}",
      "profile_image" => string_attr(attrs, "avatar_url"),
      "is_agent" => true
    })
  end

  defp maybe_update_shadow_user!(%Agent{} = agent, attrs) do
    user = agent.agent_user || Repo.preload(agent, :agent_user).agent_user

    update_attrs =
      %{}
      |> maybe_put("name", display_name_from_attrs(attrs, user.name || agent.display_name))
      |> maybe_put("profile_image", string_attr(attrs, "avatar_url"))

    update_attrs =
      case Map.get(attrs, "username") || Map.get(attrs, :username) do
        nil ->
          update_attrs

        value ->
          if agent.status != "draft" do
            Repo.rollback(:username_locked_after_publish)
          else
            username = ensure_valid_username!(value)
            Map.put(update_attrs, "username", username)
          end
      end

    if map_size(update_attrs) > 0 do
      case Accounts.update_user(user, update_attrs) do
        {:ok, _updated_user} -> :ok
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end
  end

  defp requested_or_generated_username(display_name, attrs) do
    requested = Map.get(attrs, "username") || Map.get(attrs, :username)

    case requested do
      value when is_binary(value) and String.trim(value) != "" ->
        ensure_valid_username!(value)

      _ ->
        generate_available_username(display_name)
    end
  end

  defp ensure_valid_username!(username) do
    normalized = normalize_username(username)

    cond do
      normalized == "" -> Repo.rollback(:invalid_username)
      reserved_username?(normalized) or Accounts.reserved_username?(normalized) -> Repo.rollback(:reserved_username)
      Accounts.username_exists?(normalized) -> Repo.rollback(:username_taken)
      not Regex.match?(~r/^[a-z0-9_]+$/, normalized) -> Repo.rollback(:invalid_username)
      String.length(normalized) < 3 or String.length(normalized) > 30 -> Repo.rollback(:invalid_username)
      true -> normalized
    end
  end

  defp generate_available_username(display_name) do
    base =
      display_name
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/, "_")
      |> String.trim("_")
      |> case do
        "" -> "agent"
        value -> value
      end
      |> String.slice(0, 18)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn attempt ->
      suffix = Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
      candidate = "#{base}_#{suffix}" |> String.slice(0, 30)

      cond do
        reserved_username?(candidate) ->
          nil

        Accounts.username_exists?(candidate) ->
          nil

        true ->
          candidate
      end
    end)
  end

  defp generate_secret_tuple do
    secret = "vas_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    with {:ok, encrypted} <- encrypt_secret(secret) do
      {:ok,
       %{
         secret: secret,
         hash: hash_secret(secret),
         encrypted: encrypted,
         hint: String.slice(secret, -6, 6)
       }}
    end
  end

  defp hash_secret(secret) do
    :crypto.hash(:sha256, secret)
    |> Base.encode16(case: :lower)
  end

  defp encrypt_secret(secret) when is_binary(secret) do
    iv = :crypto.strong_rand_bytes(12)
    key = callback_secret_encryption_key()

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        iv,
        secret,
        "",
        16,
        true
      )

    {:ok,
     Enum.join(
       [
         "ags1",
         Base.url_encode64(iv, padding: false),
         Base.url_encode64(ciphertext, padding: false),
         Base.url_encode64(tag, padding: false)
       ],
       "."
     )}
  rescue
    error ->
      {:error, {:secret_encryption_failed, error}}
  end

  defp decrypt_secret(ciphertext) when is_binary(ciphertext) do
    with ["ags1", iv_b64, data_b64, tag_b64] <- String.split(ciphertext, ".", parts: 4),
         {:ok, iv} <- Base.url_decode64(iv_b64, padding: false),
         {:ok, encrypted} <- Base.url_decode64(data_b64, padding: false),
         {:ok, tag} <- Base.url_decode64(tag_b64, padding: false) do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             callback_secret_encryption_key(),
             iv,
             encrypted,
             "",
             tag,
             false
           ) do
        :error -> {:error, :secret_decryption_failed}
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
      end
    else
      _ -> {:error, :secret_decryption_failed}
    end
  rescue
    _ -> {:error, :secret_decryption_failed}
  end

  defp callback_secret_encryption_key do
    seed =
      System.get_env("VIBE_AGENT_SECRET_ENCRYPTION_KEY")
      || System.get_env("VIBE_HMAC_SECRET")
      || System.get_env("SECRET_KEY_BASE")
      || Application.get_env(:vibe, VibeWeb.Endpoint, [])[:secret_key_base]
      || raise "Missing callback secret encryption seed"

    :crypto.hash(:sha256, seed)
  end

  defp map_get(map, key, fallback) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      is_binary(key) and Map.has_key?(map, String.to_existing_atom(key)) -> Map.get(map, String.to_existing_atom(key))
      true -> fallback
    end
  rescue
    ArgumentError ->
      fallback
  end

  defp string_attr(map, key) do
    case map_get(map, key, nil) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp normalize_callback_url(nil), do: nil

  defp normalize_callback_url(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_callback_url(_), do: nil

  defp display_name_from_attrs(attrs, fallback \\ "New Agent") do
    string_attr(attrs, "display_name") ||
      string_attr(attrs, "name") ||
      fallback
  end

  defp normalize_status_update(agent, attrs) do
    requested = Map.get(attrs, "status", Map.get(attrs, :status, agent.status))

    case to_string(requested || agent.status) do
      "draft" -> "draft"
      "published" -> "published"
      "disabled" -> "disabled"
      "archived" -> "archived"
      _ -> agent.status
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
