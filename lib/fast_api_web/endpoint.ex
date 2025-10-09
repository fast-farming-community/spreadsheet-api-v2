defmodule FastApiWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :fast_api

  @session_options [
    store: :cookie,
    key: "_fast_api_key",
    signing_salt: "uQ39CwOK"
  ]

  # Strict allow-list for cross-site callers
  @allowed_origins MapSet.new([
    "https://farming-community.eu",
    "https://www.farming-community.eu"
  ])

  # CORSPlug will call this; return the same origin string to allow, or false to block
  def cors_origin(origin, _conn) when is_binary(origin) do
    if MapSet.member?(@allowed_origins, origin), do: origin, else: false
  end

  def cors_origin(_origin, _conn), do: false

  plug Plug.Static,
    at: "/",
    from: :fast_api,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt)

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :fast_api
  end

  # CORS must come BEFORE parsers so preflights and error responses get headers.
  # We read options from config, fallback to a harmless default.
  plug CORSPlug,
    Application.compile_env(:fast_api, FastApiWeb.Endpoint)[:cors_plug] || [origin: false]
    # origin: false = don't add CORS unless configured

  plug Plug.RequestId
  # plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Auto-Ban Bots/Crawlers
  plug FastApiWeb.Plugs.AutoBan

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  plug FastApiWeb.Router
end
