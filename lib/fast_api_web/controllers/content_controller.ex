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
    case github_file("CHANGELOG.md") do
      {:ok, body} ->
        text(conn, body)

      {:error, {:upstream_timeout, msg}} ->
        Logger.warning("changelog: upstream timeout: #{msg}")
        send_resp(conn, 504, "Upstream timeout")

      {:error, {:upstream_status, status, _body}} ->
        Logger.warning("changelog: upstream status #{status}")
        send_resp(conn, 502, "Upstream returned #{status}")

      {:error, {:upstream_error, msg}} ->
        Logger.error("changelog: upstream error: #{msg}")
        send_resp(conn, 502, "Upstream error")
    end
  end

  def content_updates(conn, _params) do
    case github_file("WEBSITE_CONTENT_UPDATES.md") do
      {:ok, body} ->
        text(conn, body)

      {:error, {:upstream_timeout, msg}} ->
        Logger.warning("content_updates: upstream timeout: #{msg}")
        send_resp(conn, 504, "Upstream timeout")

      {:error, {:upstream_status, status, _body}} ->
        Logger.warning("content_updates: upstream status #{status}")
        send_resp(conn, 502, "Upstream returned #{status}")

      {:error, {:upstream_error, msg}} ->
        Logger.error("content_updates: upstream error: #{msg}")
        send_resp(conn, 502, "Upstream error")
    end
  end

  def todos(conn, _params) do
    case github_file("WEBSITE_TODOS.md") do
      {:ok, body} ->
        text(conn, body)

      {:error, {:upstream_timeout, msg}} ->
        Logger.warning("todos: upstream timeout: #{msg}")
        send_resp(conn, 504, "Upstream timeout")

      {:error, {:upstream_status, status, _body}} ->
        Logger.warning("todos: upstream status #{status}")
        send_resp(conn, 502, "Upstream returned #{status}")

      {:error, {:upstream_error, msg}} ->
        Logger.error("todos: upstream error: #{msg}")
        send_resp(conn, 502, "Upstream error")
    end
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

  @github_raw_base "https://raw.githubusercontent.com/fast-farming-community/public/main/"

  @finch_timeout 12_000
  @headers [{"accept", "text/plain"}]

  @spec github_file(String.t()) ::
          {:ok, binary()}
          | {:error, {:upstream_timeout, String.t()}}
          | {:error, {:upstream_status, non_neg_integer(), binary()}}
          | {:error, {:upstream_error, String.t()}}
  def github_file(filename) do
    url = @github_raw_base <> filename
    req = Finch.build(:get, url, @headers, nil)

    case Finch.request(req, FastApi.Finch, receive_timeout: @finch_timeout) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:upstream_status, status, body}}

      {:error, %Mint.TransportError{} = err} ->
        {:error, {:upstream_timeout, Exception.message(err)}}

      {:error, err} ->
        {:error, {:upstream_error, Exception.message(err)}}
    end
  end
end
