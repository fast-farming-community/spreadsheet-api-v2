defmodule FastApiWeb.ContentController do
  use FastApiWeb, :controller

  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  require Logger

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

  def changelog(conn, _params) do
    data = github_file("CHANGELOG.md")
    text(conn, data)
  end

  def content_updates(conn, _params) do
    data = github_file("WEBSITE_CONTENT_UPDATES.md")
    text(conn, data)
  end

  def todos(conn, _params) do
    data = github_file("WEBSITE_TODOS.md")
    text(conn, data)
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

  def github_file(filename) do
    :get
    |> Finch.build(
      "https://raw.githubusercontent.com/fast-farming-community/public/main/#{filename}",
      [{"Content-Type", "text"}]
    )
    |> Finch.request(FastApi.Finch)
    |> then(fn
      {:ok, %Finch.Response{body: body}} ->
        body

      {:error, error} ->
        Logger.error("Error requesting #{filename} from GitHub: #{error}")
        ""
    end)
  end
end
