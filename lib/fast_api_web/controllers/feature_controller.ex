defmodule FastApiWeb.FeatureController do
  use FastApiWeb, :controller
  alias FastApi.MongoDB

  def get_module(conn, %{"module" => module}) do
    data = MongoDB.get_module(module)
    json(conn, data)
  end

  def get_collection(conn, %{"module" => module, "collection" => collection}) do
    data = MongoDB.get_collection(module, collection)
    json(conn, data)
  end

  def get_page(conn, %{"module" => module, "collection" => collection}) do
    data = MongoDB.get_page(module, collection)
    json(conn, data)
  end

  def get_item(conn, %{"module" => module, "collection" => collection, "item" => item}) do
    data = MongoDB.get_item_by_key(module, collection, item)
    json(conn, data)
  end
end
