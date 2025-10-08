# lib/fast_api_web/controllers/stats_controller.ex
defmodule FastApiWeb.StatsController do
  use FastApiWeb, :controller
  alias FastApi.Stats

  # Accepts JSON bodies like:
  # { "type": "page_view", "route": "/guides" }
  # { "type": "click", "target": "link:/guides" } or "out:https://..."
  # { "type": "sequence", "from": "/guides", "to": "/builds" }
  def track(conn, params) do
    case sanitize(params) do
      {:ok, {:page_view, p}} -> Stats.track(:page_view, p)
      {:ok, {:click, p}}     -> Stats.track(:click, p)
      {:ok, {:sequence, p}}  -> Stats.track(:sequence, p)
      :ignore                -> :ok
      {:error, msg} ->
        conn |> put_status(:bad_request) |> json(%{error: msg}) |> halt()
    end

    json(conn, %{ok: true})
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

    json(conn, Stats.summary(%{limit: limit}))
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
