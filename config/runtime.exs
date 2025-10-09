import Config

if System.get_env("PHX_SERVER") do
  config :fast_api, FastApiWeb.Endpoint, server: true
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :fast_api, FastApiWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0,0,0,0,0,0,0,0},
      port: port,
      protocol_options: [
        request_timeout: 30_000,
        idle_timeout: 30_000
      ]
    ],
    secret_key_base: secret_key_base

  config :fast_api, FastApi.Auth.Token,
    issuer: "fast_api",
    secret_key: secret_key_base

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6"), do: [:inet6], else: []

  config :fast_api, FastApi.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  config :fast_api, FastApi.Scheduler,
    jobs: [
      {"*/5 * * * *", {FastApi.Sync.GW2API, :sync_sheet, []}},
      {"@daily",      {FastApi.Sync.GW2API, :sync_items, []}},
      {"*/5 * * * *", {FastApi.Sync.Features, :execute_cycle, []}},
      {"@hourly", {FastApi.Auth, :delete_unverified, []}},
      {"*/2 * * * *", {FastApi.Sync.Patreon, :sync_memberships, []}},
      {"@hourly", {FastApi.Sync.Patreon, :clear_memberships, []}},
      {"@hourly", {FastApi.Sync.Public, :execute, []}},
      {"@daily", {FastApi.Stats, :compact!, []}}
    ]

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Also, you may need to configure the Swoosh API client of your choice if you
  # are not using SMTP. Here is an example of the configuration:
  #
  #     config :fast_api, FastApi.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # For this example you need include a HTTP client required by Swoosh API client.
  # Swoosh supports Hackney and Finch out of the box:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Hackney
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
