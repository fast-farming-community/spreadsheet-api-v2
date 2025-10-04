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
        |> case do
          nil -> 12
          s   -> elem(Integer.parse(s || ""), 0) || 12
        end
        |> max(1) |> min(50)

      items = Search.search(q, limit)
      json(conn, %{items: items})
    end
  end

  def search(conn, _), do: json(conn, %{items: []})
end
