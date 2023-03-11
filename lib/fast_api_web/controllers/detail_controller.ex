defmodule FastApiWeb.DetailController do
  use FastApiWeb, :controller

  alias FastApi.Repos.Fast, as: Repo

  import Ecto.Query

  def get_item_page(conn, %{"module" => module, "collection" => collection, "item" => item}) do
    %{"Category" => category} = detail = get_detail(module, collection, item)

    {list, description} =
      from(t in Repo.DetailTable,
        where: t.key == ^item,
        join: f in Repo.DetailFeature,
        on: t.detail_feature_id == f.id,
        where: f.name == ^category,
        select: %{rows: t.rows, description: t.description}
      )
      |> Repo.one()
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
