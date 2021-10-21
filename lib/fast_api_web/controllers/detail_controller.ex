defmodule FastApiWeb.DetailController do
  use FastApiWeb, :controller
  alias FastApi.MongoDB

  def index(conn, %{"category" => category, "item" => item}) do
    data = MongoDB.get_item_details(category, item)
    json(conn, data)
  end

  def get_item_page(conn, %{"module" => module, "collection" => collection, "item" => item}) do
    data = MongoDB.get_item_with_details(module, collection, item)
    json(conn, data)
  end
end
