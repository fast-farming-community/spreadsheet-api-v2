defmodule FastApiWeb.Plugs.StatsFingerprint do
  @moduledoc false
  import Plug.Conn
  alias Phoenix.Token

  @cookie "fcid"
  @max_age 60 * 60 * 24 * 365
  @salt "stats_fpid"  # static salt for Phoenix.Token

  def init(opts), do: opts

  def call(conn, _opts) do
    {ip24s, ua} = {ip24(conn.remote_ip), List.first(get_req_header(conn, "user-agent")) || "?"}
    base = :crypto.hash(:sha256, "#{ip24s}|#{ua}") |> Base.url_encode64(padding: false)

    fpid =
      case fetch_cookies(conn).cookies[@cookie] do
        nil ->
          Token.sign(FastApiWeb.Endpoint, @salt, base)

        token ->
          case Token.verify(FastApiWeb.Endpoint, @salt, token, max_age: @max_age) do
            {:ok, _} -> token
            _ -> Token.sign(FastApiWeb.Endpoint, @salt, base)
          end
      end

    conn
    |> put_resp_cookie(@cookie, fpid,
         http_only: true, same_site: "Lax", secure: true, max_age: @max_age)
    |> assign(:stats_fpid, fpid)
  end

  defp ip24({a,b,c,_d}), do: "#{a}.#{b}.#{c}.0/24"
  defp ip24(_), do: "0.0.0.0/24"
end
