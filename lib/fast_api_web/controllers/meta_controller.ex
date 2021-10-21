defmodule FastApiWeb.MetaController do
  use FastApiWeb, :controller
  alias FastApi.MongoDB

  def index(conn, _params) do
    data = MongoDB.get_collection("meta", "server-meta")
    json(conn, data)
  end
end
