defmodule VibeWeb.Router do
  use VibeWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug VibeWeb.Plugs.RateLimiter, type: :api
  end

  pipeline :api_authenticated do
    plug VibeWeb.Plugs.ApiAuth, required: true
  end

  # SECURITY: Rate limited pipeline for auth endpoints
  pipeline :auth_rate_limited do
    plug :accepts, ["json"]
    plug VibeWeb.Plugs.RateLimiter, type: :auth
  end

  # SECURITY: Strict rate limiting for sensitive operations
  pipeline :strict_rate_limited do
    plug :accepts, ["json"]
    plug VibeWeb.Plugs.RateLimiter, type: :strict
  end

  # Auth endpoints with rate limiting
  scope "/api", VibeWeb do
    pipe_through :auth_rate_limited

    post "/register", AuthController, :register
    post "/login", AuthController, :login
  end

  scope "/api", VibeWeb do
    pipe_through :api

    # Health & Bootstrap
    get "/health", ApiController, :health
    get "/ping", ApiController, :ping
    get "/info", ApiController, :info
    get "/servers", ApiController, :servers
    get "/vapid-key", ApiController, :vapid_key
    get "/push/avatar/:user_id", PushAvatarController, :show
    get "/agent/document/:key", GroupAgentController, :download_document
    get "/agent/document/:key/:name", GroupAgentController, :download_document
  end

  scope "/api", VibeWeb do
    pipe_through [:api, :api_authenticated]

    # TURN/ICE credentials for WebRTC calls
    get "/turn-credentials", ApiController, :turn_credentials

    # User
    get "/user/:id", UserController, :show
    get "/user/name/:username", UserController, :show_by_name
    get "/user/phone/:phone", UserController, :show_by_phone
    post "/user/contacts/match", UserController, :match_contacts
    post "/user/profile", UserController, :update_profile
    post "/user/delete", UserController, :delete
    post "/user/block", UserController, :block
    post "/user/unblock", UserController, :unblock
    get "/user/blocks/:id", UserController, :list_blocks

    # PreKey
    get "/user/:id/prekey-bundle", EncryptionController, :get_bundle
    post "/user/prekey-bundle", EncryptionController, :upload_bundle

    # Chat
    post "/chat", ChatController, :create
    get "/chats/:user_id", ChatController, :index
    get "/chat/:chat_id/messages", ChatController, :messages
    delete "/chat/:chat_id/messages/:message_id", ChatController, :delete_message
    get "/chat/:chat_id/pinned_messages", ChatController, :list_pinned_messages
    post "/chat/:chat_id/messages/:message_id/pin", ChatController, :pin_message
    delete "/chats/:chat_id", ChatController, :delete

    # Settings
    post "/chat/:chat_id/mute", ChatController, :mute
    post "/chat/:chat_id/pin", ChatController, :pin
    post "/chat/:chat_id/mark-unread", ChatController, :mark_unread

    # Saved Messages
    get "/saved_messages/:user_id", SavedMessageController, :index
    post "/saved_messages", SavedMessageController, :create
    delete "/saved_messages/:user_id/:original_message_id", SavedMessageController, :delete

    # Subscription & Plans
    get "/plans", SubscriptionController, :list_plans
    get "/subscription/:user_id", SubscriptionController, :show
    post "/subscription/checkout", SubscriptionController, :create_checkout
    post "/subscription/cancel", SubscriptionController, :cancel

    # Referrals
    get "/referral/code/:user_id", ReferralController, :get_code
    get "/referral/stats/:user_id", ReferralController, :stats
    post "/referral/apply", ReferralController, :apply_code
    post "/referral/verify", ReferralController, :verify

    # Badges
    get "/badges/:user_id", BadgeController, :index

    # Music Streaming (Backend Proxy/Cache)
    get "/music/stream/:video_id", MusicController, :stream
    get "/music/info/:video_id", MusicController, :info

    # Business Settings
    get "/business/settings/:user_id", BusinessController, :show
    post "/business/settings", BusinessController, :update_settings

    # Stories
    post "/stories", StoryController, :create
    get "/stories/feed/:user_id", StoryController, :feed
    get "/stories/my/:user_id", StoryController, :my_stories
    get "/stories/user/:target_user_id", StoryController, :user_stories
    post "/stories/:story_id/view", StoryController, :view
    get "/stories/:story_id/viewers", StoryController, :viewers
    delete "/stories/:story_id", StoryController, :delete
    put "/stories/:story_id/visibility", StoryController, :update_visibility

    # Groups
    post "/group", GroupController, :create
    post "/group/:id/members", GroupController, :add_members
    delete "/group/:id/members/:user_id", GroupController, :remove_member

    # Group Agent
    post "/group/:id/agent", GroupAgentController, :create
    get "/group/:id/agent", GroupAgentController, :show
    put "/group/:id/agent", GroupAgentController, :update
    delete "/group/:id/agent", GroupAgentController, :delete
    post "/group/:id/agent/generate_prompt", GroupAgentController, :generate_prompt

    # Channels
    post "/channel", ChannelController, :create
    get "/channels", ChannelController, :index
    post "/channel/:id/join", ChannelController, :join
    post "/channel/:id/leave", ChannelController, :leave
    get "/channel/:id/analytics", ChannelController, :analytics

    # Scheduled Posts
    post "/channel/:id/schedule", ScheduleController, :create
    get "/channel/:id/schedule", ScheduleController, :list
    delete "/schedule/:id", ScheduleController, :cancel

    # Media Upload
    post "/media/upload", MediaController, :upload
  end

  # High-cost / abuse-prone endpoints (require auth + strict rate limit)
  scope "/api", VibeWeb do
    pipe_through [:strict_rate_limited, :api_authenticated]

    # AI Agent
    post "/agent/chat", AgentController, :chat  # SSE streaming
    post "/agent/chat/sync", AgentController, :chat_sync  # Non-streaming
    get "/agent/health", AgentController, :health

    # AI
    post "/ai/edit_image", AIController, :edit_image
  end

  # Webhooks (no auth required)
  scope "/api", VibeWeb do
    pipe_through :api
    post "/webhooks/lemonsqueezy", WebhookController, :lemon_squeezy
  end

  # Serve React SPA for all other routes
  scope "/", VibeWeb do
    get "/*path", ApiController, :index
  end
end
