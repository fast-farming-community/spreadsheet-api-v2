import Config

config :fast_api, FastApiWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :cors_plug,
  origin: [
    "https://fast.farming-community.eu",
    "https://farming-community.eu",
    "https://www.farming-community.eu"
  ],
  methods: ["GET", "POST", "OPTIONS"]

config :fast_api,
  throttle_request_limit: 10

config :logger, level: :info
