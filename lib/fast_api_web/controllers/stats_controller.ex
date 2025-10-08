defmodule FastApiWeb.StatsController do
  use FastApiWeb, :controller
  alias FastApi.Stats

  # CORS preflight handler
  def preflight(conn, _params) do
    origin = List.first(get_req_header(conn, "origin")) || "*"

    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-methods", "POST, GET, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type")
    |> put_resp_header("access-control-max-age", "86400")
    |> send_resp(204, "")
  end

  # Accepts JSON bodies like:
  # { "type": "page_view", "route": "/guides" }
  # { "type": "click", "target": "link:/guides" } or "out:https://..."
  # { "type": "sequence", "from": "/guides", "to": "/builds" }
  def track(conn, params) do
    referer = List.first(get_req_header(conn, "referer")) || ""
    allowed_host? =
      case URI.parse(referer) do
        %URI{host: h, scheme: s} when s in ["http","https"] ->
          h in ["farming-community.eu","www.farming-community.eu"]
        _ -> false
      end

    conn = allow_cors(conn)

    if not allowed_host? do
      json(conn, %{ok: true})
    else
      ctx = %{fp: conn.assigns[:stats_fpid] || "anon"}

      case sanitize(params) do
        {:ok, {t, p}} -> Stats.track(t, Map.put(p, :_ctx, ctx))
        :ignore        -> :ok
        {:error, msg}  -> conn |> put_status(:bad_request) |> json(%{error: msg}) |> halt()
      end

      json(conn, %{ok: true})
    end
  end

  def summary(conn, params) do
    limit =
      case Map.get(params, "limit") do
        nil -> 10
        s when is_binary(s) ->
          case Integer.parse(s) do
            {n, _} when n >= 1 and n <= 200 -> n
            _ -> 10
          end
        n when is_integer(n) and n > 0 -> min(n, 200)
        _ -> 10
      end

    conn = allow_cors(conn)
    json(conn, Stats.summary(%{limit: limit}))
  end

  defp allow_cors(conn) do
    origin = List.first(get_req_header(conn, "origin")) || "*"
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("vary", "Origin")
  end

  defp sanitize(%{"type" => "page_view", "route" => r}) when is_binary(r),
    do: {:ok, {:page_view, %{route: r}}}
  defp sanitize(%{"type" => "click", "target" => t}) when is_binary(t),
    do: {:ok, {:click, %{target: t}}}
  defp sanitize(%{"type" => "sequence", "from" => f, "to" => t})
       when is_binary(f) and is_binary(t),
    do: {:ok, {:sequence, %{from: f, to: t}}}
  defp sanitize(%{"type" => _}), do: {:error, "invalid payload"}
  defp sanitize(_), do: :ignore
end
