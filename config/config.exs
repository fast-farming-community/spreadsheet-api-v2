# config/config.exs
import Config

config :fast_api, FastApiWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [view: FastApiWeb.ErrorView, accepts: ~w(html json), layout: false],
  pubsub_server: FastApi.PubSub,
  live_view: [signing_salt: "N7gdh9BX"]

config :fast_api, FastApi.Mailer,
  adapter: Swoosh.Adapters.Sendmail,
  cmd_path: "/usr/sbin/sendmail"

config :fast_api, FastApi.Repo, priv: "priv/fast"

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
  format: "$time [$level] $message\n"

config :phoenix, :logger,
  level: :warning,
  filter_parameters: ["password", "token", "authorization"]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
