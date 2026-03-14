defmodule Vibe.RelayRegistry do
  @moduledoc """
  In-memory registry for VibeNet relay nodes.

  Uses ETS for fast concurrent reads/writes.
  Relays are ephemeral — they only exist while the relay node is connected.
  """

  use GenServer

  @table :relay_registry

  # ─── Public API ──────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Register a new relay node"
  def register_relay(relay) do
    :ets.insert(@table, {relay.relay_id, relay})
    :ok
  end

  @doc "Update a relay's metadata"
  def update_relay(relay_id, updates) do
    case :ets.lookup(@table, relay_id) do
      [{^relay_id, existing}] ->
        updated = Map.merge(existing, updates)
        :ets.insert(@table, {relay_id, updated})
        :ok
      [] ->
        :not_found
    end
  end

  @doc "Remove a relay from the registry"
  def unregister_relay(relay_id) do
    :ets.delete(@table, relay_id)
    :ok
  end

  @doc "Find a relay by invite code"
  def find_by_invite_code(code) do
    result =
      :ets.foldl(
        fn {_id, relay}, acc ->
          if relay[:invite_code] == code do
            [relay | acc]
          else
            acc
          end
        end,
        [],
        @table
      )

    case result do
      [relay | _] ->
        {:ok, relay_to_map(relay)}
      [] ->
        :not_found
    end
  end

  @doc "List all public relays"
  def list_public_relays do
    :ets.foldl(
      fn {_id, relay}, acc ->
        if relay[:is_public] do
          [relay_to_map(relay) |> Map.put(:uptime, calculate_uptime(relay[:started_at])) | acc]
        else
          acc
        end
      end,
      [],
      @table
    )
  end

  @doc "Get relay count"
  def count do
    :ets.info(@table, :size)
  end

  # ─── GenServer Callbacks ─────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  # ─── Helpers ─────────────────────────────────────────────────

  defp calculate_uptime(nil), do: 0
  defp calculate_uptime(started_at) do
    elapsed = System.system_time(:second) - started_at
    min(100, div(elapsed, 36)) # rough percentage based on 1 hour = 100%
  end

  defp relay_to_map(relay) do
    %{
      relay_id: relay.relay_id,
      name: relay[:name] || "Relay",
      invite_key: relay[:invite_key],
      invite_code: relay[:invite_code],
      is_public: relay[:is_public] || false,
      region: relay[:region] || "unknown",
      current_peers: relay[:current_peers] || 0,
      max_peers: relay[:max_peers] || 5,
      tags: [],
      external_ip: relay[:external_ip],
      bridge_url: relay[:bridge_url],
      share_link: relay[:share_link],
      bridge_descriptor: relay[:bridge_descriptor]
    }
  end
end
