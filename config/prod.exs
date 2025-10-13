import Config

config :fast_api, FastApiWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  http: [
    port: String.to_integer(System.get_env("PORT") || "4000"),
    transport_options: [
      num_acceptors: 10,
      max_connections: 1024
    ],
    protocol_options: [
      idle_timeout: 30_000,
      request_timeout: 15_000,
      max_keepalive: 50
    ]
  ]

config :logger, level: :info
