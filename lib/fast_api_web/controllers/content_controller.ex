defmodule FastApiWeb.ContentController do
  use FastApiWeb, :controller

  alias FastApi.Repos.Fast, as: Repo

  def index(conn, _params) do
    data =
      Repo.About
      |> Repo.all()
      |> Enum.filter(& &1.published)

    json(conn, data)
  end

  def builds(conn, _params) do
    data =
      Repo.Build
      |> Repo.all()
      |> Enum.filter(& &1.published)

    json(conn, data)
  end

  def contributors(conn, _params) do
    data =
      Repo.Contributor
      |> Repo.all()
      |> Enum.filter(& &1.published)

    json(conn, data)
  end

  def guides(conn, _params) do
    data =
      Repo.Guide
      |> Repo.all()
      |> Enum.filter(& &1.published)

    json(conn, data)
  end
end
