import Config

config :fast_api, FastApiWeb.Endpoint,
  url: [host: "api.farming-community.eu", port: 40000],
  cache_static_manifest: "priv/static/cache_manifest.json"

config :cors_plug,
  origin: [
    "https://fast.farming-community.eu",
    "https://farming-community.eu",
    "https://www.farming-community.eu"
  ],
  methods: ["GET"]

config :fast_api,
  throttle_request_limit: 10

config :logger, level: :info
