defmodule FastApiWeb.ContentController do
  use FastApiWeb, :controller

  alias FastApi.Content.Utils
  alias FastApi.Repos.Content, as: Repo

  def index(conn, _params) do
    data =
      Repo.About
      |> Repo.all()
      |> Enum.map(&Utils.parse_content/1)
      |> Enum.filter(& &1.published)

    json(conn, data)
  end

  def builds(conn, _params) do
    data =
      Repo.FarmingBuild
      |> Repo.all()
      |> Enum.map(&Utils.parse_content/1)

    json(conn, data)
  end

  def contributors(conn, _params) do
    data =
      Repo.Contributor
      |> Repo.all()
      |> Enum.map(&Utils.parse_content/1)

    json(conn, data)
  end

  def guides(conn, _params) do
    data =
      Repo.FarmingGuide
      |> Repo.all()
      |> Enum.map(&Utils.parse_content/1)
      |> Enum.filter(& &1.published)

    json(conn, data)
  end
end
