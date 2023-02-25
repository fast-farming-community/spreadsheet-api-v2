defmodule FastApi.MongoDB do
  alias FastApi.Content.Schema
  alias FastApi.MongoPipelines

  def get_module(database) do
    :mongo
    |> Mongo.show_collections(database: database)
    |> Enum.to_list()
    |> Enum.reduce([], fn collection, collections ->
      collection_map = %{name: collection, tables: get_collection(database, collection)}
      [collection_map | collections]
    end)
  end

  def get_collection(database, collection) do
    :mongo
    |> Mongo.find(collection, %{}, database: database)
    |> Enum.to_list()
  end

  def get_page(database, collection) do
    :mongo
    |> Mongo.aggregate(collection, MongoPipelines.build_page_document(), database: database)
    |> Enum.to_list()
  end

  def get_item_by_key(database, collection, key) do
    :mongo
    |> Mongo.find_one(collection, %{"Key" => key}, database: database)
    |> Enum.into(%{})
  end

  def get_item_details(database, collection) do
    get_collection("#{database}-details", collection)
  end

  def get_item_with_details(database, collection, key) do
    %{"Category" => category, "Key" => item_key} =
      item = get_item_by_key(database, collection, key)

    list = get_item_details(category, item_key)

    %{detail: item, list: list}
  end

  def upload(%Schema.Spreadsheet{feature: feature, entries: entries}) do
    # Mongo.delete_many(:mongo, )
    # Mongo
  end
end

defimpl Jason.Encoder, for: BSON.ObjectId do
  def encode(val, _opts \\ []) do
    val
    |> BSON.ObjectId.encode!()
    |> Jason.encode!()
  end
end
