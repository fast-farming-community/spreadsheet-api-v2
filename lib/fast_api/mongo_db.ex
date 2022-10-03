defmodule FastApi.MongoDB do
  alias FastApi.MongoPipelines

  def get_collection(database, collection) do
    cursor = Mongo.find(:mongo, collection, %{}, database: database)

    Enum.to_list(cursor)
  end

  def get_page(database, collection) do
    cursor =
      Mongo.aggregate(:mongo, collection, MongoPipelines.build_page_document(), database: database)

    Enum.to_list(cursor)
  end

  def get_item_by_key(database, collection, key) do
    result = Mongo.find_one(:mongo, collection, %{"Key" => key}, database: database)

    Enum.into(result, %{})
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
end

defimpl Jason.Encoder, for: BSON.ObjectId do
  def encode(val, _opts \\ []) do
    val
    |> BSON.ObjectId.encode!()
    |> Jason.encode!()
  end
end
