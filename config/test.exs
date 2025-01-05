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

secret_key = "ih4cDxQd4vOY/WlfymlhKUhT/QTCdBYMtxjm50Oc5uUPyApy5ql7XJHXV+9pmfq/"

config :cors_plug,
  origin: ["http://localhost:4200"],
  methods: ["GET"]

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :fast_api, FastApiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: secret_key,
  server: true

config :fast_api, FastApi.Auth.Token,
  issuer: "fast_api",
  secret_key: secret_key

# In test we don't send emails.
config :fast_api, FastApi.Mailer, adapter: Swoosh.Adapters.Test

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
