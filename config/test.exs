import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :fast_api, FastApi.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "fast_api_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :fast_api, FastApiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ih4cDxQd4vOY/WlfymlhKUhT/QTCdBYMtxjm50Oc5uUPyApy5ql7XJHXV+9pmfq/",
  server: false

config :fast_api,
  mongo_host: "localhost:27017",
  mongo_uname: "mongo",
  mongo_password: "mongo"

# In test we don't send emails.
config :fast_api, FastApi.Mailer, adapter: Swoosh.Adapters.Test

# Print only warnings and errors during test
config :logger, level: :warn

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
