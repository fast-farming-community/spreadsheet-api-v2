defmodule FastApiWeb.MetaController do
  use FastApiWeb, :controller

  alias FastApi.Repos.Fast, as: Repo

  def index(conn, _params) do
    Repo.Metadata
    |> Repo.all()
    |> Enum.map(fn
      %{data: ""} = meta -> meta
      meta -> %Repo.Metadata{meta | data: Jason.decode!(meta.data)}
    end)
    |> then(&json(conn, &1))
  end
end
