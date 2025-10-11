defmodule FastApiWeb.HealthController do
  use FastApiWeb, :controller
  import Plug.Conn

  @topic "health"

  def show(conn, _params) do
    s = FastApi.Health.Server.get()
    json(conn, %{up: s.up, since: s.since, updated_at: s.updated_at, reason: s.reason})
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

    _ = sse(conn, FastApi.Health.Server.get())

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
end
