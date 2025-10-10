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

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream; charset=utf-8")
      |> put_resp_header("cache-control", "no-cache, no-transform")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    Phoenix.PubSub.subscribe(FastApi.PubSub, topic)
    {:ok, conn} = sse(conn, FastApi.Health.Gw2Server.get(key))

    parent = self()
    heartbeat = spawn_link(fn -> heartbeat_loop(parent) end)
    loop(conn, heartbeat)
  end

  defp loop(conn, heartbeat) do
    receive do
      {:health, state} ->
        case sse(conn, state) do
          {:ok, conn} -> loop(conn, heartbeat)
          {:error, _} -> exit(:normal)
        end
      {:heartbeat} ->
        case chunk(conn, "event: ping\ndata: {}\n\n") do
          {:ok, conn} -> loop(conn, heartbeat)
          {:error, _} -> exit(:normal)
        end
    after
      60_000 ->
        case chunk(conn, "event: ping\ndata: {}\n\n") do
          {:ok, conn} -> loop(conn, heartbeat)
          {:error, _} -> exit(:normal)
        end
    end
  end

  defp heartbeat_loop(parent) do
    receive do
    after 25_000 -> :ok end
    send(parent, {:heartbeat})
    heartbeat_loop(parent)
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
