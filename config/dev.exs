# config/dev.exs
import Config

config :fast_api, FastApi.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "fast_api_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

secret_key = "yxwt7JC4UkmUV307Qu2gjS+RgMisRtcdCruJUNwQrXRafqPuGb7ZXPzx9e8RmsaO"

config :fast_api, FastApiWeb.Endpoint,
  # Bind as you prefer; leaving your original bind
  http: [
    ip: {127, 0, 0, 1},
    port: 4000,
    protocol_options: [
      request_timeout: 30_000,
      idle_timeout: 30_000
    ]
  ],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: secret_key,
  watchers: []

config :fast_api, FastApi.Auth.Token,
  issuer: "fast_api",
  secret_key: secret_key

config :fast_api, FastApiWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/fast_api_web/(live|views)/.*(ex)$",
      ~r"lib/fast_api_web/templates/.*(eex)$"
    ]
  ]

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
