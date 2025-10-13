defmodule FastApiWeb.CorsController do
  use FastApiWeb, :controller

  @allowed [
    "https://fast.farming-community.eu",
    "https://farming-community.eu",
    "https://www.farming-community.eu"
  ]

  @localhost_rx ~r/^http:\/\/(localhost|127\.0\.0\.1):\d+$/

  def preflight(conn, _params) do
    origin = List.first(get_req_header(conn, "origin"))
    acrh   = List.first(get_req_header(conn, "access-control-request-headers")) || ""

    if allowed_origin?(origin) do
      conn
      |> put_resp_header("access-control-allow-origin", origin)
      |> put_resp_header("access-control-allow-credentials", "true")
      |> put_resp_header("access-control-allow-methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS,HEAD")
      |> put_resp_header("access-control-allow-headers", acrh)
      |> put_resp_header("access-control-max-age", "86400")
      |> put_resp_header("vary", "origin")
      |> send_resp(204, "")
    else
      send_resp(conn, 403, "Forbidden")
    end
  end

  defp allowed_origin?(nil), do: false
  defp allowed_origin?(o) when is_binary(o),
    do: o in @allowed or Regex.match?(@localhost_rx, o)
end
