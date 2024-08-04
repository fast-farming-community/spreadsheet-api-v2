import Config

config :fast_api, FastApiWeb.Endpoint,
  url: [host: "api-v2.farming-community.eu", port: 40000],
  cache_static_manifest: "priv/static/cache_manifest.json"

config :cors_plug,
  origin: [
    "https://test.farming-community.eu",
    "https://farming-community.eu",
    "https://www.farming-community.eu"
  ],
  methods: ["GET"]

config :logger, level: :info
