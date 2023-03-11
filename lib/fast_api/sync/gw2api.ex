defmodule FastApi.Sync.GW2API do
  import Ecto.Query, only: [from: 2]

  alias FastApi.Repos.Fast, as: Repo
  alias Finch

  require Logger

  @dailies "https://api.guildwars2.com/v2/achievements/daily"
  @items "https://api.guildwars2.com/v2/items"
  @prices "https://api.guildwars2.com/v2/commerce/prices"
  @step 150

  @spec dailies() :: :ok
  def dailies do
    dailies =
      get_dailies()
      |> Map.drop(["fractals", "special"])
      |> Enum.flat_map(fn {type, dailies} ->
        Enum.map(dailies, fn daily ->
          [
            type,
            daily["id"],
            daily["level"]["min"],
            daily["level"]["max"],
            Enum.join(daily["required_access"], ", ")
          ]
        end)
      end)

    {:ok, token} = Goth.Token.for_scope("https://www.googleapis.com/auth/spreadsheets")
    connection = GoogleApi.Sheets.V4.Connection.new(token.token)

    {:ok, _response} =
      GoogleApi.Sheets.V4.Api.Spreadsheets.sheets_spreadsheets_values_update(
        connection,
        "1WdwWxyP9zeJhcxoQAr-paMX47IuK6l5rqAPYDOA8mho",
        "DailyAPI!A4:G#{4 + length(dailies)}",
        body: %{values: dailies},
        valueInputOption: "RAW"
      )

    :ok
  end

  # WIP: Cleanup
  @spec sync_items() :: :ok
  def sync_items do
    item_ids = get_item_ids()
    commerce_item_ids = get_commerce_item_ids()

    {tradable, non_tradable} = Enum.split_with(item_ids, &(&1 in commerce_item_ids))

    tradable
    |> get_details(@items)
    |> Enum.map(&to_item(&1, true))
    |> Enum.each(&Repo.insert(&1, on_conflict: :replace_all, conflict_target: [:id]))

    non_tradable
    |> get_details(@items)
    |> Enum.map(&to_item/1)
    |> Enum.each(&Repo.insert(&1, on_conflict: :replace_all, conflict_target: [:id]))

    :ok
  end

  @spec sync_prices() :: :ok
  def sync_prices do
    from(item in Repo.Item,
      where: item.tradable == true,
      select: item
    )
    |> Repo.all()
    |> then(&Enum.zip(&1, get_details(Enum.map(&1, fn item -> item.id end), @prices)))
    |> Enum.map(fn {item, changes} -> Repo.Item.changeset(item, changes) end)
    |> Enum.each(&Repo.update/1)
  end

  def sync_sheet do
    sync_prices()

    items =
      Repo.Item
      |> Repo.all()
      |> Enum.map(fn %Repo.Item{} = item ->
        [item.id, item.name, item.buy, item.sell, item.icon, item.rarity, item.vendor_value]
      end)

    {:ok, token} = Goth.Token.for_scope("https://www.googleapis.com/auth/spreadsheets")
    connection = GoogleApi.Sheets.V4.Connection.new(token.token)

    {:ok, _response} =
      GoogleApi.Sheets.V4.Api.Spreadsheets.sheets_spreadsheets_values_update(
        connection,
        "1WdwWxyP9zeJhcxoQAr-paMX47IuK6l5rqAPYDOA8mho",
        "API!A4:G#{4 + length(items)}",
        body: %{values: items},
        valueInputOption: "RAW"
      )
  end

  defp get_details(ids, base_url) do
    ids
    |> Enum.chunk_every(@step)
    |> Enum.flat_map(fn chunk ->
      Finch.build(:get, "#{base_url}?ids=#{Jason.encode!(chunk)}")
      |> request_json()
    end)
    |> Enum.map(&keys_to_atoms/1)
  end

  defp get_dailies do
    Finch.build(:get, @dailies)
    |> request_json()
  end

  defp get_item_ids do
    Finch.build(:get, @items)
    |> request_json()
  end

  defp get_commerce_item_ids do
    Finch.build(:get, @prices)
    |> request_json()
  end

  defp request_json(request) do
    request
    |> Finch.request(FastApi.Finch)
    |> then(fn
      {:ok, %Finch.Response{body: body}} ->
        Jason.decode!(body)

      {:error, error} ->
        Logger.error("Error requesting #{request.path}: #{inspect(error)}")
    end)
  end

  defp keys_to_atoms(map) do
    Enum.into(map, %{}, fn {key, value} -> {String.to_atom(key), value} end)
  end

  defp to_item(params, tradable \\ false) do
    params
    |> Map.put(:tradable, tradable)
    |> then(&struct(Repo.Item, &1))
  end
end
