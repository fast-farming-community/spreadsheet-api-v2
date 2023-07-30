defmodule FastApiWeb.MetaController do
  use FastApiWeb, :controller

  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  def index(conn, _params) do
    Fast.Metadata
    |> Repo.all()
    |> Enum.map(fn
      %{data: data} = meta when is_nil(data) or data == "" -> meta
      meta -> %Fast.Metadata{meta | data: Jason.decode!(meta.data)}
    end)
    |> then(&json(conn, &1))
  end
end
