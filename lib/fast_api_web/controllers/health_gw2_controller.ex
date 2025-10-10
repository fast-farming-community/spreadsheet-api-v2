defmodule FastApiWeb.HealthGw2Controller do
  use FastApiWeb, :controller
  import Plug.Conn
  @topic "health:gw2"

  def show(conn, _params) do
    s = FastApi.Health.Gw2Server.get()
    json(conn, Map.take(s, [:up, :since, :updated_at, :reason]))
  end

  def stream(conn, _params) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream; charset=utf-8")
      |> put_resp_header("cache-control", "no-cache, no-transform")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    Phoenix.PubSub.subscribe(FastApi.PubSub, @topic)

    {:ok, conn} = sse(conn, FastApi.Health.Gw2Server.get())

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
end
