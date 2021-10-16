import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :fast_api, FastApiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "pOQ1icnkm6YL9B1she2o4QzUyc7iC7P1JkwqF9gtENwV1qThVeosSFBKLNhc3KbX",
  server: false

# In test we don't send emails.
config :fast_api, FastApi.Mailer,
  adapter: Swoosh.Adapters.Test

# Print only warnings and errors during test
config :logger, level: :warn

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
