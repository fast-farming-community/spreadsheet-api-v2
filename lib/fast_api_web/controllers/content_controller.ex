defmodule FastApiWeb.ContentController do
  use FastApiWeb, :controller

  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  def index(conn, _params) do
    data =
      Fast.About
      |> Repo.all()
      |> Enum.filter(& &1.published)
      |> Enum.sort_by(& &1.order, :asc)

    json(conn, data)
  end

  def builds(conn, _params) do
    data =
      Fast.Build
      |> Repo.all()
      |> Enum.filter(& &1.published)

    json(conn, data)
  end

  def contributors(conn, _params) do
    data =
      Fast.Contributor
      |> Repo.all()
      |> Enum.filter(& &1.published)

    json(conn, data)
  end

  def guides(conn, _params) do
    data =
      Fast.Guide
      |> Repo.all()
      |> Enum.filter(& &1.published)
      |> Enum.sort_by(& &1.order, :asc)

    json(conn, data)
  end
end
