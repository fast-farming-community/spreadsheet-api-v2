defmodule FastApiWeb.Plugs.SimpleCORS do
  @moduledoc false
  import Plug.Conn

  @allowed_origins [
    "https://farming-community.eu",
    "https://www.farming-community.eu"
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    origin = get_req_header(conn, "origin") |> List.first()

    conn =
      if origin in @allowed_origins do
        conn
        |> put_resp_header("access-control-allow-origin", origin)
        |> put_resp_header("access-control-allow-methods", "GET,POST,OPTIONS")
        |> put_resp_header("access-control-allow-headers", "content-type")
        |> put_resp_header("access-control-max-age", "86400")
        |> put_resp_header("vary", "Origin")
      else
        conn
      end

    if conn.method == "OPTIONS" do
      conn |> send_resp(204, "") |> halt()
    else
      conn
    end
  end
end
