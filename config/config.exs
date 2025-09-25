# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Configures the endpoint
config :fast_api, FastApiWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [view: FastApiWeb.ErrorView, accepts: ~w(html json), layout: false],
  pubsub_server: FastApi.PubSub,
  live_view: [signing_salt: "N7gdh9BX"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
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

# Swoosh API client is needed for adapters other than SMTP.
config :swoosh, :api_client, false

# Configures Elixir's Logger
config :logger, level: :warn

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Silence Phoenix request logs
config :phoenix, :logger,
  level: :warn,
  filter_parameters: ["password", "token", "authorization"]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
