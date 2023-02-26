defmodule FastApiWeb.FeatureController do
  use FastApiWeb, :controller
  alias FastApi.MongoDB

  alias FastApi.Repos.Fast, as: Repo

  def get_module(conn, %{"module" => module}) do
    data = MongoDB.get_module(module)
    json(conn, data)
  end

  def get_page(conn, %{"module" => _module, "collection" => collection}) do
    data =
      Repo.Page
      |> Repo.get_by(name: collection)
      |> Repo.preload(:tables)
      |> then(fn page ->
        Enum.map(page.tables, &%Repo.Table{&1 | rows: Jason.decode!(&1.rows)})
      end)

    json(conn, data)
  end

  def get_item(conn, %{"module" => module, "collection" => collection, "item" => item}) do
    data = MongoDB.get_item_by_key(module, collection, item)
    json(conn, data)
  end
end
