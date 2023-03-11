defmodule FastApiWeb.DetailController do
  use FastApiWeb, :controller

  alias FastApi.Repos.Fast, as: Repo

  def get_item_page(conn, %{"collection" => collection, "item" => item}) do
    detail =
      Repo.Page
      |> Repo.get_by(name: collection)
      |> Repo.preload(:tables)
      |> then(fn page -> Enum.flat_map(page.tables, &Jason.decode!(&1.rows)) end)
      |> Enum.find(fn
        %{"Key" => ^item} -> true
        _ -> false
      end)

    {list, description} =
      Repo.DetailTable
      |> Repo.get_by(key: item)
      |> then(&{Jason.decode!(&1.rows), &1.description})

    json(conn, %{description: description, detail: detail, list: list})
  end
end
