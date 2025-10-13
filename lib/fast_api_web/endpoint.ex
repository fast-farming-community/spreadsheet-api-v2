defmodule FastApiWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :fast_api

  @session_options [
    store: :cookie,
    key: "_fast_api_key",
    signing_salt: "uQ39CwOK"
  ]

  plug CORSPlug

  plug :cors_preflight_fastpath

  plug(fn conn, _ -> Plug.Conn.put_resp_header(conn, "vary", "origin") end)

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

  defp cors_preflight_fastpath(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    origin = List.first(Plug.Conn.get_req_header(conn, "origin"))
    acrh   = List.first(Plug.Conn.get_req_header(conn, "access-control-request-headers")) || ""

    if allowed_origin?(origin) do
      conn
      |> Plug.Conn.put_resp_header("access-control-allow-origin", origin)
      |> Plug.Conn.put_resp_header("access-control-allow-credentials", "true")
      |> Plug.Conn.put_resp_header("access-control-allow-methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS,HEAD")
      |> Plug.Conn.put_resp_header("access-control-allow-headers", acrh)
      |> Plug.Conn.put_resp_header("access-control-max-age", "86400")
      |> Plug.Conn.send_resp(204, "")
      |> Plug.Conn.halt()
    else
      conn |> Plug.Conn.send_resp(403, "Forbidden") |> Plug.Conn.halt()
    end
  end

  defp cors_preflight_fastpath(conn, _opts), do: conn

  @allowed_cors_origins [
    "https://fast.farming-community.eu",
    "https://farming-community.eu",
    "https://www.farming-community.eu"
  ]
  @localhost_rx ~r/^http:\/\/(localhost|127\.0\.0\.1):\d+$/
  defp allowed_origin?(nil), do: false
  defp allowed_origin?(o) when is_binary(o),
    do: o in @allowed_cors_origins or Regex.match?(@localhost_rx, o)
end
