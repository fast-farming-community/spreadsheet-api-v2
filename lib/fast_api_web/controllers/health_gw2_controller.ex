defmodule FastApiWeb.HealthGw2Controller do
  use FastApiWeb, :controller
  import Plug.Conn

  def show(conn, %{"endpoint" => ep}) do
    key = normalize(ep)
    s = FastApi.Health.Gw2Server.get(key)
    json(conn, s)
  end

  def stream(conn, %{"endpoint" => ep}) do
    key = normalize(ep)
    topic = "health:gw2:" <> to_string(key)
    origin = List.first(get_req_header(conn, "origin"))

    conn =
      conn
      |> (fn c -> if origin, do: put_resp_header(c, "access-control-allow-origin", origin), else: c end).()
      |> put_resp_header("access-control-allow-credentials", "true")
      |> put_resp_header("vary", "origin")
      |> put_resp_header("content-type", "text/event-stream; charset=utf-8")
      |> put_resp_header("cache-control", "no-cache, no-transform")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    Phoenix.PubSub.subscribe(FastApi.PubSub, topic)

    _ = sse(conn, FastApi.Health.Gw2Server.get(key))

    shutdown_ref = Process.send_after(self(), :sse_shutdown, 60_000)
    loop(conn, shutdown_ref)
  end

  defp loop(conn, shutdown_ref) do
    receive do
      :sse_shutdown ->
        _ = chunk(conn, "event: ping\ndata: closing\n\n")
        Plug.Conn.halt(conn)

      {:health, state} ->
        case sse(conn, state) do
          {:ok, conn} -> loop(conn, shutdown_ref)
          {:error, _} -> :ok
        end
    after
      15_000 ->
        _ = chunk(conn, "event: ping\ndata: {}\n\n")
        loop(conn, shutdown_ref)
    end
  end

  defp sse(conn, %{up: up, since: since, updated_at: updated_at, reason: reason}) do
    data = Jason.encode!(%{up: up, since: since, updated_at: updated_at, reason: reason})
    chunk(conn, "event: health\ndata: #{data}\n\n")
  end

  defp normalize("items"), do: :items
  defp normalize("currencies"), do: :currencies
  defp normalize("commerce_listings"), do: :commerce_listings
  defp normalize("commerce-prices"), do: :commerce_prices
  defp normalize("commerce_prices"), do: :commerce_prices
  defp normalize("exchange_gems"), do: :exchange_gems
  defp normalize("exchange-gems"), do: :exchange_gems
  defp normalize(x) when is_binary(x), do: String.to_atom(x)
end
