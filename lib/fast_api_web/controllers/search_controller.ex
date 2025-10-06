defmodule FastApiWeb.SearchController do
  use FastApiWeb, :controller
  alias FastApi.Search

  def search(conn, %{"q" => q0} = params) do
    q = String.trim(q0 || "")

    if String.length(q) < 2 do
      json(conn, %{items: []})
    else
      limit =
        params["limit"]
        |> parse_int(12)
        |> clamp(1, 50)

      items = Search.search(q, limit)
      json(conn, %{items: items})
    end
  end

  def search(conn, _), do: json(conn, %{items: []})

  defp parse_int(nil, default), do: default
  defp parse_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp clamp(n, min, _max) when n < min, do: min
  defp clamp(n, _min, max) when n > max, do: max
  defp clamp(n, _min, _max), do: n
end
