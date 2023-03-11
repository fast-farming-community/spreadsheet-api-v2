# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :fast_api,
  ecto_repos: [FastApi.Repo]

# Configures the endpoint
config :fast_api, FastApiWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [view: FastApiWeb.ErrorView, accepts: ~w(html json), layout: false],
  pubsub_server: FastApi.PubSub,
  live_view: [signing_salt: "N7gdh9BX"]

config :fast_api,
  cockpit_token: System.get_env("COCKPIT_TOKEN"),
  cockpit_url: "https://fast.farming-community.eu/cockpit/api/collection/get/"

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :fast_api, FastApi.Mailer, adapter: Swoosh.Adapters.Local

config :fast_api,
  ecto_repos: [FastApi.Repos.Content, FastApi.Repos.Fast]

config :fast_api, FastApi.Repos.Content, database: "priv/repo/config/collections.sqlite"
config :fast_api, FastApi.Repos.Fast, priv: "priv/fast"

# Swoosh API client is needed for adapters other than SMTP.
config :swoosh, :api_client, false

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
