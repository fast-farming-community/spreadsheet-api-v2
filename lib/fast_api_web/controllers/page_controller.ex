defmodule FastApiWeb.PageController do
  use FastApiWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end
end
