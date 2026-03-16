defmodule Vibe.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @apns_prod "https://api.push.apple.com"
  @apns_sandbox "https://api.sandbox.push.apple.com"

  @impl true
  def start(_type, _args) do
    # Create ETS table for rate limiting before starting the endpoint
    # This must happen before any requests can hit the RateLimiter plug
    ensure_ets_table(:rate_limiter)
    ensure_ets_table(:chat_home_cache)

    children = [
      # Start the Telemetry supervisor
      # VibeWeb.Telemetry,
      # Start the Ecto repository
      Vibe.Repo,
      # Start the PubSub system
      {Phoenix.PubSub, name: Vibe.PubSub},
      # Start Presence tracking
      VibeWeb.Presence,
      # Start Finch HTTP client for AI APIs
      {Finch, name: Vibe.Finch},
      # APNs requires HTTP/2; keep a dedicated Finch instance so other outbound HTTP is unaffected
      {Finch,
       name: Vibe.APNsFinch,
       pools: %{
         @apns_prod => [protocols: [:http2]],
         @apns_sandbox => [protocols: [:http2]],
         default: [protocols: [:http2]]
       }},
      # Start the Endpoint (http/https)
      VibeWeb.Endpoint,
      # Start the Relay Registry (VibeNet peer relay network)
      Vibe.RelayRegistry,
      # Start the scheduled post scheduler
      # Start the scheduled post scheduler
      Vibe.Scheduler,
      Vibe.AgentDeliveryScheduler,
      # Start the Story Cleaner
      Vibe.StoryCleaner
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Vibe.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    VibeWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp ensure_ets_table(name) do
    case :ets.whereis(name) do
      :undefined ->
        :ets.new(name, [:set, :public, :named_table, {:read_concurrency, true}])

      _tid ->
        :ok
    end
  end

end
