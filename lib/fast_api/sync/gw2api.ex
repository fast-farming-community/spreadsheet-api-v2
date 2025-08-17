defmodule FastApi.Sync.GW2API do
  @moduledoc "Synchronize the spreadsheet using GW2 API data."
  import Ecto.Query, only: [from: 2]

  alias FastApi.Repo
  alias FastApi.Schemas.Fast

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

    {:ok, token} = Goth.fetch(FastApi.Goth)
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
    from(item in Fast.Item,
      where: item.tradable == true,
      select: item
    )
    |> Repo.all()
    |> get_item_details()
    |> Enum.each(fn
      {%Fast.Item{id: id, vendor_value: vendor_value} = item,
       %{id: id, buys: %{"unit_price" => buy} = buys} = changes} ->
        buy = if is_nil(buy) or buy == 0, do: vendor_value, else: buy

        item
        |> Fast.Item.changeset(%{changes | buys: %{buys | "unit_price" => buy}})
        |> Repo.update()

      {item, changes} ->
        Logger.error("Mismatching ids for item #{inspect(item)} and data #{inspect(changes)}")
    end)
  end

  defp get_item_details(items) do
    items
    |> Enum.chunk_every(@step)
    |> Enum.flat_map(fn chunk ->
      req_url = "#{@prices}?ids=#{Enum.map_join(chunk, ",", & &1.id)}"

      result = Finch.build(:get, req_url) |> request_json() |> Enum.map(&keys_to_atoms/1)
      result_ids = Enum.map(result, & &1.id)

      # TODO: Maybe instead return `nil` for mismatching items and have the DB step
      # take care of removing mismatching items
      case Enum.split_with(chunk, fn item -> item.id in result_ids end) do
        {_, []} ->
          Enum.zip(chunk, result)

        {matching, mismatching} ->
          Logger.error("Found mismatching items: #{inspect(mismatching)}")
          Enum.zip(matching, result)
      end
    end)
  end

  def sync_sheet do
    sync_prices()

    items =
      Fast.Item
      |> Repo.all()
      |> Enum.map(fn %Fast.Item{} = item ->
        [item.id, item.name, item.buy, item.sell, item.icon, item.rarity, item.vendor_value]
      end)
      |> Enum.sort_by(&List.first/1)

    {:ok, token} = Goth.fetch(FastApi.Goth)
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
      req_url = "#{base_url}?ids=#{Enum.join(chunk, ",")}"

      Finch.build(:get, req_url)
      |> request_json()
      |> tap(fn
        result when length(result) == length(chunk) ->
          :ok

        result ->
          missing_ids = chunk -- Enum.map(result, &Map.get(&1, "id"))
          Logger.error("Missing IDs for #{req_url}: #{inspect(missing_ids)}")
      end)
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
  
  defp request_json(request, retry \\ 0) do
    case Finch.request(request, FastApi.Finch) do
      {:ok, %Finch.Response{body: body}} ->
        case Jason.decode(body) do
          {:ok, decoded} when is_list(decoded) ->
            decoded

          {:ok, decoded} when is_map(decoded) ->
            [decoded]  # wrap map in list for Enum.flat_map

          {:ok, other} ->
            Logger.error("Unexpected response from #{request.path}: #{inspect(other)}")
            []

          {:error, error} ->
            Logger.error("Failed to decode JSON from #{request.path}: #{inspect(error)}")
            []
        end

      {:error, %Mint.TransportError{reason: :timeout}} when retry < 5 ->
        request_json(request, retry + 1)

      {:error, error} ->
        Logger.error("Error requesting #{request.path}: #{inspect(error)}")
        []
    end
  end

  defp keys_to_atoms(map) do
    Enum.into(map, %{}, fn {key, value} -> {String.to_atom(key), value} end)
  end

  defp to_item(params, tradable \\ false) do
    params
    |> Map.put(:tradable, tradable)
    |> then(&struct(Fast.Item, &1))
  end
end
