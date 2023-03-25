defmodule FastApiWeb.FeatureController do
  use FastApiWeb, :controller

  alias FastApi.Repos.Fast, as: Repo

  def get_page(conn, %{"collection" => "overview"}) do
    json(conn, [])
  end

  def get_page(conn, %{"collection" => collection}) do
    Repo.Page
    |> Repo.get_by(name: collection)
    |> Repo.preload(:tables)
    |> then(fn page ->
      page.tables
      |> Enum.map(&%Repo.Table{&1 | rows: Jason.decode!(&1.rows)})
      |> Enum.sort_by(& &1.order)
    end)
    |> then(&json(conn, &1))
  end
end
