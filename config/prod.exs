import Config

config :fast_api, FastApiWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  http: [
    port: String.to_integer(System.get_env("PORT") || "4000")
  ]

config :logger, level: :info
