defmodule FastApiWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :fast_api

  @session_options [
    store: :cookie,
    key: "_fast_api_key",
    signing_salt: "uQ39CwOK"
  ]

  # Single, proper CORS handling (CORSPlug uses your config)
  plug CORSPlug

  plug :put_vary_origin

  plug Plug.Static,
    at: "/",
    from: :fast_api,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt)

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :fast_api
  end

  plug Plug.RequestId
  plug FastApiWeb.Plugs.AutoBan

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  plug FastApiWeb.Router

  defp put_vary_origin(conn, _opts) do
    Plug.Conn.put_resp_header(conn, "vary", "origin")
  end
end
