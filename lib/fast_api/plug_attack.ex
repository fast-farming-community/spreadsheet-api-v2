defmodule FastApi.PlugAttack do
  use PlugAttack

  import Plug.Conn

  @limit Application.compile_env!(:fast_api, :throttle_request_limit)

  rule "throttle by ip", conn do
    throttle(conn.remote_ip,
      period: 60_000,
      limit: @limit,
      storage: {PlugAttack.Storage.Ets, FastApi.PlugAttack.Storage}
    )
  end

  def allow_action(conn, {:throttle, data}, opts) do
    conn
    |> add_throttling_headers(data)
    |> allow_action(true, opts)
  end

  def allow_action(conn, _data, _opts) do
    conn
  end

  def block_action(conn, {:throttle, data}, opts) do
    conn
    |> add_throttling_headers(data)
    |> block_action(nil, opts)
  end

  def block_action(conn, _data, _opts) do
    conn
    |> send_resp(
      :too_many_requests,
      Jason.encode!(%{error: "Rate limit exceeded for the requested resource."})
    )
    |> halt()
  end

  defp add_throttling_headers(conn, data) do
    reset = div(data[:expires_at], 1_000)

    conn
    |> put_resp_header("x-ratelimit-limit", to_string(data[:limit]))
    |> put_resp_header("x-ratelimit-remaining", to_string(data[:remaining]))
    |> put_resp_header("x-ratelimit-reset", to_string(reset))
  end
end
