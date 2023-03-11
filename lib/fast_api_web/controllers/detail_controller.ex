defmodule FastApiWeb.DetailController do
  use FastApiWeb, :controller

  alias FastApi.Repos.Fast, as: Repo

  def get_item_page(conn, %{"module" => module, "collection" => collection, "item" => item}) do
    detail = get_detail(module, collection, item)

    {list, description} =
      Repo.DetailTable
      |> Repo.get_by(key: item)
      |> then(&{Jason.decode!(&1.rows), &1.description})

    json(conn, %{description: description, detail: detail, list: list})
  end

  defp get_detail(module, collection, item) do
    if String.contains?(module, "details") do
      Repo.DetailTable
      |> Repo.get_by(key: collection)
      |> then(&Jason.decode!(&1.rows))
      |> Enum.find(fn
        %{"Key" => ^item} -> true
        _ -> false
      end)
    else
      Repo.Page
      |> Repo.get_by(name: collection)
      |> Repo.preload(:tables)
      |> then(fn page -> Enum.flat_map(page.tables, &Jason.decode!(&1.rows)) end)
      |> Enum.find(fn
        %{"Key" => ^item} -> true
        _ -> false
      end)
    end
  end
end
