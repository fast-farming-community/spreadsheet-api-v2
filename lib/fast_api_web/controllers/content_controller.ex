defmodule FastApiWeb.ContentController do
  use FastApiWeb, :controller

  alias FastApi.Repo
  alias FastApi.Schemas.Fast
  import Ecto.Query
  require Logger

  @github_raw_base "https://raw.githubusercontent.com/fast-farming-community/public/main/"
  @finch_timeout 12_000
  @headers [{"accept", "text/plain"}]

  # ... (rest unchanged)

  def github_file(filename) do
    url = @github_raw_base <> filename
    req = Finch.build(:get, url, @headers, nil)

    case Finch.request(req, FastApi.FinchPublic, receive_timeout: @finch_timeout) do
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
