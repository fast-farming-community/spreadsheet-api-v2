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
      Enum.map(page.tables, &%Repo.Table{&1 | rows: Jason.decode!(&1.rows)})
    end)
    |> then(&json(conn, &1))
  end
end
