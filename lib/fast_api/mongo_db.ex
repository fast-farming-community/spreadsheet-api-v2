defmodule FastApi.MongoDB do
  alias FastApi.MongoPipelines

  def get_collection(database, collection) do
    with {:ok, conn} <- Mongo.start_link(url: url(), database: database) do
      cursor = Mongo.find(conn, collection, %{})

      cursor
      |> Enum.to_list()
    end
  end

  def get_page(database, collection) do
    with {:ok, conn} <- Mongo.start_link(hostname: "localhost", database: database) do
      cursor = Mongo.aggregate(conn, collection, MongoPipelines.build_page_document())

      cursor
      |> Enum.to_list()
    end
  end

  def get_item_by_key(database, collection, key) do
    with {:ok, conn} <- Mongo.start_link(hostname: "localhost", database: database) do
      result = Mongo.find_one(conn, collection, %{"Key" => key})

      result
      |> Enum.into(%{})
    end
  end

  def get_item_details(database, collection) do
    get_collection(~s(#{database}-details), collection)
  end

  def get_item_with_details(database, collection, key) do
    item = get_item_by_key(database, collection, key)
    list = get_item_details(Map.get(item, "Category"), Map.get(item, "Key"))

    %{
      "detail" => item,
      "list" => list
    }
  end

  defp url() do
    username = Application.fetch_env!(:fast_api, :db_uname)
    password = Application.fetch_env!(:fast_api, :db_password)
    url = Application.fetch_env!(:fast_api, :db_url)

    ~s(mongodb://#{if(username || password, do: username <> ":" <> password <> "@")}#{url})
  end
end

defimpl Jason.Encoder, for: BSON.ObjectId do
  def encode(val, _opts \\ []) do
    BSON.ObjectId.encode!(val)
    |> Jason.encode!()
  end
end
