defmodule FastApiWeb.HealthController do
  use FastApiWeb, :controller

  @topic "health"

  def show(conn, _params) do
    s = FastApi.Health.Server.get()
    json(conn, %{up: s.up, since: s.since, updated_at: s.updated_at, reason: s.reason})
  end

  # text/event-stream endpoint
  def stream(conn, _params) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    Phoenix.PubSub.subscribe(FastApi.PubSub, @topic)

    # send initial snapshot
    {:ok, conn} = sse(conn, FastApi.Health.Server.get())

    # heartbeat every 25s to keep proxies happy
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
        # safety timeout: still alive? send a ping
        case chunk(conn, "event: ping\ndata: {}\n\n") do
          {:ok, conn} -> loop(conn, heartbeat)
          {:error, _} -> exit(:normal)
        end
    end
  end

  defp heartbeat_loop(parent) do
    receive do after 25_000 -> :ok end
    send(parent, {:heartbeat})
    heartbeat_loop(parent)
  end

  defp sse(conn, %{up: up, since: since, updated_at: updated_at, reason: reason}) do
    data = Jason.encode!(%{up: up, since: since, updated_at: updated_at, reason: reason})
    chunk(conn, "event: health\ndata: #{data}\n\n")
  end
end
