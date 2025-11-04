import Config

config :fast_api, FastApiWeb.Endpoint,
  render_errors: [view: FastApiWeb.ErrorView, accepts: ~w(html json), layout: false],
  pubsub_server: FastApi.PubSub,
  live_view: [signing_salt: "N7gdh9BX"]

config :cors_plug,
  origin: [
    "https://fast.farming-community.eu",
    "https://farming-community.eu",
    "https://www.farming-community.eu",
    ~r/^http:\/\/(localhost|127\.0\.0\.1):\d+$/
  ],
  methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"],
  headers: [
    "authorization","content-type","accept","origin","x-requested-with",
    "last-event-id","cache-control","pragma","dnt","user-agent","if-modified-since",
    "range","x-client-version"
  ],
  expose: ["content-length", "content-disposition"],
  credentials: true,
  max_age: 86_400,
  send_preflight_response?: true

config :fast_api, FastApi.Mailer,
  adapter: Swoosh.Adapters.Sendmail,
  cmd_path: "/usr/sbin/sendmail"

config :fast_api, FastApi.Raffle,
  api_key: System.get_env("RAFFLE_GW2_API_KEY"),
  character: System.get_env("RAFFLE_GW2_CHARACTER")

config :fast_api, FastApi.Repo, priv: "priv/fast"
config :fast_api, frontend_base_url: "https://fast.farming-community.eu"

config :fast_api,
  patreon_api_key: System.get_env("PATREON_API_KEY"),
  patreon_campaign: System.get_env("PATREON_CAMPAIGN")

config :fast_api,
  ecto_repos: [FastApi.Repo],
  access_token_ttl: {1, :hours},
  refresh_token_ttl: {4, :weeks},
  throttle_request_limit: 100

config :swoosh, :api_client, false

config :logger,
  level: :info

config :logger, :console,
  format: "$date $time [$level] $message\n"

config :phoenix, :logger,
  level: :warning,
  filter_parameters: ["password", "token", "authorization"]

config :mime, :types, %{
  "text/event-stream" => ["event-stream"]
}

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
