defmodule FastApi.Sync.GW2API do
  @moduledoc "Synchronize the spreadsheet using GW2 API data."
  import Ecto.Query, only: [from: 2, where: 3, select: 3, order_by: 3]

  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  require Logger

  @items "https://api.guildwars2.com/v2/items"
  @prices "https://api.guildwars2.com/v2/commerce/prices"
  @step 150
  @concurrency System.schedulers_online() * 2

  defp fmt_ms(ms) do
    total = div(ms, 1000)
    mins = div(total, 60)
    secs = rem(total, 60)
    "#{mins}:#{String.pad_leading(Integer.to_string(secs), 2, "0")} mins"
  end

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

  @spec sync_prices() :: {:ok, non_neg_integer}
  def sync_prices do
    t0 = System.monotonic_time(:millisecond)

    items =
      Fast.Item
      |> where([i], i.tradable == true)
      |> select([i], %{id: i.id, vendor_value: i.vendor_value})
      |> Repo.all()

    pairs =
      items
      |> Enum.chunk_every(@step)
      |> Task.async_stream(&fetch_prices_for_chunk/1,
        max_concurrency: @concurrency,
        timeout: 30_000
      )
      |> Enum.flat_map(fn
        {:ok, pairs} -> pairs
        {:exit, reason} ->
          Logger.error("concurrent fetch failed: #{inspect(reason)}")
          []
      end)

    rows =
      pairs
      |> Enum.map(fn
        {%{id: id, vendor_value: vendor}, %{"buys" => buys, "sells" => sells}} ->
          buy0  = buys  && Map.get(buys,  "unit_price")
          sell0 = sells && Map.get(sells, "unit_price")
          buy   = if is_nil(buy0) or buy0 == 0, do: vendor, else: buy0
          sell  = if is_nil(sell0), do: 0, else: sell0
          %{id: id, buy: buy, sell: sell}
        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    updated =
      rows
      |> Enum.chunk_every(5_000)
      |> Enum.reduce(0, fn batch, acc ->
        batch_with_ts =
          Enum.map(batch, fn row ->
            row
            |> Map.put_new(:inserted_at, now) # for the rare case a new row appears
            |> Map.put(:updated_at, now)
          end)

        {count, _} =
          Repo.insert_all(
            Fast.Item,
            batch_with_ts,
            on_conflict: {:replace, [:buy, :sell, :updated_at]},
            conflict_target: [:id]
          )

        acc + count
      end)

    dt = System.monotonic_time(:millisecond) - t0
    Logger.info("[job] gw2.sync_prices completed in #{fmt_ms(dt)} updated=#{updated}")

    {:ok, updated}
  end

  # Helper: fetch price maps for a chunk and align them with items by id
  defp fetch_prices_for_chunk(chunk) do
    ids = Enum.map(chunk, & &1.id)
    req_url = "#{@prices}?ids=#{Enum.map_join(ids, ",", & &1)}"

    Finch.build(:get, req_url)
    |> request_json()
    |> then(fn result ->
      by_id =
        result
        |> Enum.filter(&match?(%{"id" => _}, &1))
        |> Map.new(&{&1["id"], &1})

      for %{id: id} = item <- chunk, Map.has_key?(by_id, id) do
        {item, Map.fetch!(by_id, id)}
      end
    end)
  end

  def sync_sheet do
    t0 = System.monotonic_time(:millisecond)

    {:ok, updated_prices} = sync_prices()

    items =
      Fast.Item
      |> select([i], [i.id, i.name, i.buy, i.sell, i.icon, i.rarity, i.vendor_value])
      |> order_by([i], asc: i.id)
      |> Repo.all()

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

    dt = System.monotonic_time(:millisecond) - t0
    Logger.info("[job] gw2.sync_sheet completed in #{fmt_ms(dt)} prices_updated=#{updated_prices} rows_written=#{length(items)}")

    :ok
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
      {:ok, %Finch.Response{status: status, body: body}} ->
        case Jason.decode(body) do
          {:ok, decoded} when is_list(decoded) ->
            if status != 200 do
              Logger.error("HTTP #{status} with list body from remote: #{inspect(Enum.take(decoded, 1))}")
            end
            decoded
          {:ok, decoded} when is_map(decoded) ->
            if status != 200 do
              Logger.error("HTTP #{status} with map body from remote: #{inspect(decoded)}")
            end
            [decoded]
          {:ok, _other} ->
            Logger.error("Unexpected JSON shape (status #{status})")
            []
          {:error, error} ->
            Logger.error("Failed to decode JSON (status #{status}): #{inspect(error)} body_snippet=#{inspect(String.slice(to_string(body), 0, 400))}")
            []
        end
      {:error, %Mint.TransportError{reason: :timeout}} when retry < 5 ->
        request_json(request, retry + 1)
      {:error, error} ->
        Logger.error("HTTP request error: #{inspect(error)}")
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
